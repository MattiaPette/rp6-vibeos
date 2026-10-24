// SPDX-License-Identifier: GPL-2.0-only
/*
 * kgsl-shim: a read-only /sys/class/kgsl/kgsl-3d0 on top of the mainline
 * msm driver.
 *
 * DroidDeck (and other Android apps written for Qualcomm's KGSL driver)
 * decide whether the device has an Adreno GPU, and which one, by reading
 * /sys/class/kgsl/kgsl-3d0. They also read the GPU load, clock and
 * temperature from there for their HUD. Mainline Linux drives the GPU with
 * DRM msm and has no KGSL, so this module publishes the same files, filled
 * from the msm GPU's devfreq and the GPU thermal zone.
 *
 * Nothing here touches the GPU: no device node, no ioctls. The device node
 * (/dev/kgsl-3d0) is the msm render node, created by a udev rule.
 */

#include <linux/device.h>
#include <linux/devfreq.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/pm_opp.h>
#include <linux/sysfs.h>
#include <linux/thermal.h>

static char *gpu_model = "Adreno740v2";
module_param(gpu_model, charp, 0444);
MODULE_PARM_DESC(gpu_model, "Name published in gpu_model (KGSL style)");

static char *thermal_zone = "gpuss-0-thermal";
module_param(thermal_zone, charp, 0444);
MODULE_PARM_DESC(thermal_zone, "Thermal zone read for temp");

static struct device *kgsl_dev;

/* msm, pinned once found; see pin_driver(). */
static struct module *gpu_owner;
static DEFINE_MUTEX(pin_lock);

/* The msm GPU is the node compatible with "qcom,adreno" (not the GMU). */
static struct device_node *gpu_node(void)
{
	return of_find_compatible_node(NULL, NULL, "qcom,adreno");
}

/* The GPU's platform device, with a reference the caller drops. */
static struct device *gpu_device(void)
{
	struct device_node *np = gpu_node();
	struct platform_device *pdev;

	if (!np)
		return NULL;
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	return pdev ? &pdev->dev : NULL;
}

/*
 * When the last reference to a devfreq goes, the devfreq core calls back
 * into its driver's profile, which lives in the msm module. Readers here
 * may hold that last reference, so keep msm loaded for as long as this
 * module is. Built-in msm has no owner and needs nothing.
 */
static bool pin_driver(struct device *gpu)
{
	bool ok;

	mutex_lock(&pin_lock);
	device_lock(gpu);
	ok = gpu->driver && (gpu_owner || !gpu->driver->owner);
	if (gpu->driver && !ok && try_module_get(gpu->driver->owner)) {
		gpu_owner = gpu->driver->owner;
		ok = true;
	}
	device_unlock(gpu);
	mutex_unlock(&pin_lock);
	return ok;
}

static int is_devfreq(struct device *dev, const void *data)
{
	return dev->class && !strcmp(dev->class->name, "devfreq");
}

/*
 * The GPU's devfreq, looked up on every read (msm may bind after this
 * module loads, or unbind and bind again) and held by a reference to its
 * device, which keeps the struct alive even if msm removes it meanwhile.
 * Release with put_devfreq().
 */
static struct devfreq *get_devfreq(void)
{
	struct device *gpu = gpu_device();
	struct device *dev = NULL;

	if (!gpu)
		return NULL;
	if (pin_driver(gpu))
		dev = device_find_child(gpu, NULL, is_devfreq);
	put_device(gpu);
	return dev ? container_of(dev, struct devfreq, dev) : NULL;
}

static void put_devfreq(struct devfreq *df)
{
	put_device(&df->dev);
}

struct gpu_state {
	unsigned long cur_freq;
	unsigned long min_freq;
	unsigned long max_freq;
	unsigned long busy;
	unsigned long total;
};

static bool read_state(struct gpu_state *s)
{
	struct devfreq *df = get_devfreq();

	memset(s, 0, sizeof(*s));
	if (!df)
		return false;
	mutex_lock(&df->lock);
	s->cur_freq = df->previous_freq;
	s->min_freq = df->scaling_min_freq;
	s->max_freq = df->scaling_max_freq;
	s->busy = df->last_status.busy_time;
	s->total = df->last_status.total_time;
	mutex_unlock(&df->lock);
	put_devfreq(df);
	return true;
}

static unsigned int busy_percent(const struct gpu_state *s)
{
	if (!s->total)
		return 0;
	return min_t(u64, 100, div64_u64((u64)s->busy * 100, s->total));
}

/*
 * From the OPP table rather than devfreq's freq_table, which msm can free
 * while a reader holds the devfreq; the OPP calls take their own references.
 */
static ssize_t freq_list(char *buf)
{
	struct device *gpu = gpu_device();
	unsigned long freqs[32], f = 0;
	struct dev_pm_opp *opp;
	ssize_t len = 0;
	int n = 0;

	if (gpu) {
		while (n < ARRAY_SIZE(freqs) && !IS_ERR(opp = dev_pm_opp_find_freq_ceil(gpu, &f))) {
			dev_pm_opp_put(opp);
			freqs[n++] = f++;
		}
		put_device(gpu);
	}
	/* KGSL lists the fastest level first. */
	while (n--)
		len += sysfs_emit_at(buf, len, n ? "%lu " : "%lu", freqs[n]);
	len += sysfs_emit_at(buf, len, "\n");
	return len;
}

static ssize_t gpu_model_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", gpu_model);
}
static DEVICE_ATTR_RO(gpu_model);

/* The chip id is the hex suffix of the GPU's "qcom,adreno-XXXXXXXX" compatible. */
static ssize_t gpu_chipid_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct device_node *np = gpu_node();
	const char *compat;
	unsigned int id = 0;
	int i;

	for (i = 0; np && !of_property_read_string_index(np, "compatible", i, &compat); i++)
		if (sscanf(compat, "qcom,adreno-%x", &id) == 1)
			break;
	of_node_put(np);
	return sysfs_emit(buf, "0x%08x\n", id);
}
static DEVICE_ATTR_RO(gpu_chipid);

static ssize_t gpubusy_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%7lu %7lu\n", s.busy, s.total);
}
static DEVICE_ATTR_RO(gpubusy);

static ssize_t gpu_busy_percentage_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%u %%\n", busy_percent(&s));
}
static DEVICE_ATTR_RO(gpu_busy_percentage);

static ssize_t gpuclk_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%lu\n", s.cur_freq);
}
static DEVICE_ATTR_RO(gpuclk);

static ssize_t max_gpuclk_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%lu\n", s.max_freq);
}
static DEVICE_ATTR_RO(max_gpuclk);

static ssize_t min_clock_mhz_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%lu\n", s.min_freq / 1000000);
}
static DEVICE_ATTR_RO(min_clock_mhz);

static ssize_t clock_mhz_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%lu\n", s.cur_freq / 1000000);
}
static DEVICE_ATTR_RO(clock_mhz);

static ssize_t gpu_available_frequencies_show(struct device *dev, struct device_attribute *attr,
					      char *buf)
{
	return freq_list(buf);
}
static DEVICE_ATTR_RO(gpu_available_frequencies);

/* Millidegrees Celsius, like KGSL on recent kernels. */
static ssize_t temp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct thermal_zone_device *tz = thermal_zone_get_zone_by_name(thermal_zone);
	int t;

	if (IS_ERR(tz) || thermal_zone_get_temp(tz, &t))
		return -ENODATA;
	return sysfs_emit(buf, "%d\n", t);
}
static DEVICE_ATTR_RO(temp);

static struct attribute *kgsl_attrs[] = {
	&dev_attr_gpu_model.attr,
	&dev_attr_gpu_chipid.attr,
	&dev_attr_gpubusy.attr,
	&dev_attr_gpu_busy_percentage.attr,
	&dev_attr_gpuclk.attr,
	&dev_attr_max_gpuclk.attr,
	&dev_attr_min_clock_mhz.attr,
	&dev_attr_clock_mhz.attr,
	&dev_attr_gpu_available_frequencies.attr,
	&dev_attr_temp.attr,
	NULL,
};

static const struct attribute_group kgsl_group = {
	.attrs = kgsl_attrs,
};

/* devfreq/: the subset of a devfreq directory KGSL users read. */
static ssize_t cur_freq_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return gpuclk_show(dev, attr, buf);
}
static DEVICE_ATTR_RO(cur_freq);

static ssize_t max_freq_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return max_gpuclk_show(dev, attr, buf);
}
static DEVICE_ATTR_RO(max_freq);

static ssize_t min_freq_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%lu\n", s.min_freq);
}
static DEVICE_ATTR_RO(min_freq);

static ssize_t available_frequencies_show(struct device *dev, struct device_attribute *attr,
					  char *buf)
{
	return freq_list(buf);
}
static DEVICE_ATTR_RO(available_frequencies);

static ssize_t gpu_load_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gpu_state s;

	read_state(&s);
	return sysfs_emit(buf, "%u\n", busy_percent(&s));
}
static DEVICE_ATTR_RO(gpu_load);

static struct attribute *devfreq_attrs[] = {
	&dev_attr_cur_freq.attr,
	&dev_attr_max_freq.attr,
	&dev_attr_min_freq.attr,
	&dev_attr_available_frequencies.attr,
	&dev_attr_gpu_load.attr,
	NULL,
};

static const struct attribute_group devfreq_group = {
	.name = "devfreq",
	.attrs = devfreq_attrs,
};

static const struct attribute_group *kgsl_groups[] = {
	&kgsl_group,
	&devfreq_group,
	NULL,
};

static const struct class kgsl_class = {
	.name = "kgsl",
};

static int __init kgsl_shim_init(void)
{
	int ret = class_register(&kgsl_class);

	if (ret)
		return ret;
	/* No dev_t: the device node is the msm render node, made by udev. */
	kgsl_dev = device_create_with_groups(&kgsl_class, NULL, MKDEV(0, 0), NULL, kgsl_groups,
					     "kgsl-3d0");
	if (IS_ERR(kgsl_dev)) {
		class_unregister(&kgsl_class);
		return PTR_ERR(kgsl_dev);
	}
	return 0;
}

static void __exit kgsl_shim_exit(void)
{
	device_unregister(kgsl_dev);
	class_unregister(&kgsl_class);
	if (gpu_owner)
		module_put(gpu_owner);
}

module_init(kgsl_shim_init);
module_exit(kgsl_shim_exit);

MODULE_DESCRIPTION("KGSL-style sysfs view of the msm Adreno GPU");
MODULE_LICENSE("GPL");
