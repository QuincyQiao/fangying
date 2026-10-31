// 用 FFmpeg 直接读视频：时长、画面尺寸、某一时刻的缩略图。
// 侧栏列表和进度条悬停预览用，不经过 mpv，也不开解码线程池。
#pragma once
#include <stdint.h>

typedef struct {
    double duration;   // 秒，读不到为 0
    int width;         // 显示尺寸（已按像素宽高比和旋转换算），没有画面为 0
    int height;
} fy_info;

typedef struct {
    uint8_t *data;     // BGRA，调用方用 fy_image_free 释放
    int width;
    int height;
    int stride;
    double time;       // 实际取到的那一帧的时间
} fy_image;

// 返回 0 成功；1 没有画面（纯音频）；负数打不开。
int fy_probe(const char *path, fy_info *info);

// 取 seconds 处的一帧，缩到 max_w × max_h 以内。fraction ≥ 0 时改按时长比例取（0.1 = 10% 处）。
// keyframe_only 为 1 时只解关键帧（悬停预览用，快）；为 0 时解到目标时刻那一帧。
int fy_thumbnail(const char *path, double seconds, double fraction, int max_w, int max_h,
                 int keyframe_only, fy_image *out);

void fy_image_free(fy_image *img);
