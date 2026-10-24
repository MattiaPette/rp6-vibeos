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
#include <linux/sysfs.h>
#include <linux/thermal.h>

static char *gpu_model = "Adreno740v2";
module_param(gpu_model, charp, 0444);
MODULE_PARM_DESC(gpu_model, "Name published in gpu_model (KGSL style)");

static char *thermal_zone = "gpuss-0";
module_param(thermal_zone, charp, 0444);
MODULE_PARM_DESC(thermal_zone, "Thermal zone read for temp");

static struct device *kgsl_dev;

/* The msm GPU is the node compatible with "qcom,adreno" (not the GMU). */
static struct device_node *gpu_node(void)
{
	return of_find_compatible_node(NULL, NULL, "qcom,adreno");
}

/*
 * Looked up on every read: the msm driver may bind after this module
 * loads, or unbind and bind again.
 */
static struct devfreq *gpu_devfreq(void)
{
	struct device_node *np = gpu_node();
	struct devfreq *df;

	if (!np)
		return NULL;
	df = devfreq_get_devfreq_by_node(np);
	of_node_put(np);
	return IS_ERR(df) ? NULL : df;
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
	struct devfreq *df = gpu_devfreq();

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
	return true;
}

static unsigned int busy_percent(const struct gpu_state *s)
{
	if (!s->total)
		return 0;
	return min_t(u64, 100, div64_u64((u64)s->busy * 100, s->total));
}

static ssize_t freq_list(char *buf)
{
	struct devfreq *df = gpu_devfreq();
	ssize_t len = 0;
	int i;

	if (!df)
		return sysfs_emit(buf, "\n");
	mutex_lock(&df->lock);
	/* KGSL lists the fastest level first. */
	for (i = df->max_state - 1; i >= 0; i--)
		len += sysfs_emit_at(buf, len, "%lu ", df->freq_table[i]);
	mutex_unlock(&df->lock);
	if (len)
		len--;
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
}

module_init(kgsl_shim_init);
module_exit(kgsl_shim_exit);

MODULE_DESCRIPTION("KGSL-style sysfs view of the msm Adreno GPU");
MODULE_LICENSE("GPL");
