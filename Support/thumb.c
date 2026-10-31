#include "thumb.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t quiet_once = PTHREAD_ONCE_INIT;
static void make_quiet(void) { av_log_set_level(AV_LOG_QUIET); }

static int open_input(const char *path, AVFormatContext **out) {
    pthread_once(&quiet_once, make_quiet);
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return -1;
    *out = fmt;
    return 0;
}

// 找真正的画面流，跳过 MKV/MP4 里当封面的图片流。
static int find_video(AVFormatContext *fmt) {
    int best = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (best >= 0 && !(fmt->streams[best]->disposition & AV_DISPOSITION_ATTACHED_PIC)) return best;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(st->disposition & AV_DISPOSITION_ATTACHED_PIC))
            return (int)i;
    }
    return -1;
}

static int rotation_of(AVStream *st) {
    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data,
                                                         st->codecpar->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * 4) return 0;
    double r = -av_display_rotation_get((const int32_t *)sd->data);
    if (isnan(r)) return 0;
    int deg = ((int)lround(r) % 360 + 360) % 360;
    return (deg + 45) / 90 * 90 % 360;
}

static void display_size(AVStream *st, int w, int h, int *dw, int *dh) {
    AVRational sar = st->sample_aspect_ratio.num ? st->sample_aspect_ratio : st->codecpar->sample_aspect_ratio;
    double fw = w, fh = h;
    if (sar.num > 0 && sar.den > 0) fw = w * (double)sar.num / sar.den;
    if (rotation_of(st) % 180 == 90) { double t = fw; fw = fh; fh = t; }
    *dw = (int)lround(fw);
    *dh = (int)lround(fh);
}

int fy_probe(const char *path, fy_info *info) {
    memset(info, 0, sizeof(*info));
    AVFormatContext *fmt = NULL;
    if (open_input(path, &fmt) < 0) return -1;
    int vi = find_video(fmt);
    if (fmt->duration <= 0 || vi < 0 || fmt->streams[vi]->codecpar->width == 0) {
        fmt->probesize = 4 << 20;
        fmt->max_analyze_duration = 2 * AV_TIME_BASE;
        if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return -2; }
        vi = find_video(fmt);
    }
    if (fmt->duration > 0) info->duration = fmt->duration / (double)AV_TIME_BASE;
    if (vi >= 0) {
        AVStream *st = fmt->streams[vi];
        display_size(st, st->codecpar->width, st->codecpar->height, &info->width, &info->height);
        if (info->duration <= 0 && st->duration > 0) info->duration = st->duration * av_q2d(st->time_base);
    }
    avformat_close_input(&fmt);
    return vi >= 0 ? 0 : 1;
}

static uint8_t *rotate_bgra(const uint8_t *src, int w, int h, int stride, int deg, int *ow, int *oh) {
    int nw = (deg % 180 == 90) ? h : w, nh = (deg % 180 == 90) ? w : h;
    uint8_t *dst = malloc((size_t)nw * nh * 4);
    if (!dst) return NULL;
    for (int y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)(src + (size_t)y * stride);
        for (int x = 0; x < w; x++) {
            int nx, ny;
            switch (deg) {
                case 90:  nx = h - 1 - y; ny = x; break;
                case 180: nx = w - 1 - x; ny = h - 1 - y; break;
                default:  nx = y; ny = w - 1 - x; break; // 270
            }
            ((uint32_t *)dst)[(size_t)ny * nw + nx] = row[x];
        }
    }
    *ow = nw; *oh = nh;
    return dst;
}

int fy_thumbnail(const char *path, double seconds, double fraction, int max_w, int max_h,
                 int keyframe_only, fy_image *out) {
    memset(out, 0, sizeof(*out));
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL, *picked = NULL;
    struct SwsContext *sws = NULL;
    int ret = -1;

    if (open_input(path, &fmt) < 0) return -1;
    fmt->probesize = 4 << 20;
    fmt->max_analyze_duration = AV_TIME_BASE;
    if (avformat_find_stream_info(fmt, NULL) < 0) goto done;
    int vi = find_video(fmt);
    if (vi < 0) { ret = 1; goto done; }
    AVStream *st = fmt->streams[vi];

    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) goto done;
    dec = avcodec_alloc_context3(codec);
    if (!dec || avcodec_parameters_to_context(dec, st->codecpar) < 0) goto done;
    dec->thread_count = 4;
    dec->thread_type = FF_THREAD_SLICE;  // 帧级多线程要先攒几帧才出图，取单帧反而慢
    if (keyframe_only) dec->skip_frame = AVDISCARD_NONKEY;
    if (avcodec_open2(dec, codec, NULL) < 0) goto done;

    double duration = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    double target = fraction >= 0 ? duration * fraction : seconds;
    if (duration > 0 && target > duration - 0.5) target = duration > 1 ? duration - 0.5 : 0;
    if (target < 0) target = 0;
    double start = st->start_time != AV_NOPTS_VALUE ? st->start_time * av_q2d(st->time_base) : 0;
    int64_t ts = (int64_t)((target + start) / av_q2d(st->time_base));
    if (target > 0) av_seek_frame(fmt, vi, ts, AVSEEK_FLAG_BACKWARD);

    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    if (!pkt || !frame) goto done;

    // 第二轮兜底：TS 这类按时间二分查找的格式可能落在关键帧之后、解不出图，这时回到开头取第一帧
    for (int attempt = 0; attempt < 2 && !picked; attempt++) {
        if (attempt == 1) {
            if (target <= 0) break;
            avcodec_flush_buffers(dec);
            av_seek_frame(fmt, vi, st->start_time != AV_NOPTS_VALUE ? st->start_time : 0, AVSEEK_FLAG_BACKWARD);
            target = 0;
        }
        int packets = 0, eof = 0;
        while (!picked && packets < 2000) {
            if (!eof) {
                int r = av_read_frame(fmt, pkt);
                if (r < 0) { eof = 1; avcodec_send_packet(dec, NULL); }
                else {
                    if (pkt->stream_index == vi) { avcodec_send_packet(dec, pkt); packets++; }
                    av_packet_unref(pkt);
                }
            }
            for (;;) {
                int r = avcodec_receive_frame(dec, frame);
                if (r < 0) break;
                int64_t pts = frame->best_effort_timestamp;
                double t = pts != AV_NOPTS_VALUE ? pts * av_q2d(st->time_base) - start : target;
                if (keyframe_only || t >= target - 0.02 || eof) {
                    picked = av_frame_clone(frame);
                    out->time = t;
                    av_frame_unref(frame);
                    break;
                }
                av_frame_unref(frame);
            }
            if (eof && !picked) break;  // 解码器已经吐完
        }
    }
    if (!picked) goto done;

    int dw, dh;
    display_size(st, picked->width, picked->height, &dw, &dh);
    int rot = rotation_of(st);
    // 先按旋转前的方向算缩放尺寸
    int pre_w = (rot % 180 == 90) ? dh : dw, pre_h = (rot % 180 == 90) ? dw : dh;
    int box_w = (rot % 180 == 90) ? max_h : max_w, box_h = (rot % 180 == 90) ? max_w : max_h;
    double scale = fmin((double)box_w / pre_w, (double)box_h / pre_h);
    if (scale > 1) scale = 1;
    int tw = (int)fmax(2, lround(pre_w * scale)), th = (int)fmax(2, lround(pre_h * scale));

    sws = sws_getContext(picked->width, picked->height, picked->format, tw, th, AV_PIX_FMT_BGRA,
                         SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) goto done;
    int stride = tw * 4;
    uint8_t *buf = malloc((size_t)stride * th);
    if (!buf) goto done;
    uint8_t *dst[4] = {buf, NULL, NULL, NULL};
    int dst_stride[4] = {stride, 0, 0, 0};
    sws_scale(sws, (const uint8_t *const *)picked->data, picked->linesize, 0, picked->height, dst, dst_stride);
    for (int i = 0; i < tw * th; i++) buf[i * 4 + 3] = 255;

    if (rot) {
        int rw, rh;
        uint8_t *r = rotate_bgra(buf, tw, th, stride, rot, &rw, &rh);
        free(buf);
        if (!r) goto done;
        buf = r; tw = rw; th = rh; stride = rw * 4;
    }
    out->data = buf;
    out->width = tw;
    out->height = th;
    out->stride = stride;
    ret = 0;

done:
    sws_freeContext(sws);
    av_frame_free(&picked);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return ret;
}

void fy_image_free(fy_image *img) {
    free(img->data);
    img->data = NULL;
}
