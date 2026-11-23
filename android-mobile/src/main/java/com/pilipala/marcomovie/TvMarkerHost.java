package com.pilipala.marcomovie;

import android.view.KeyEvent;
import android.widget.FrameLayout;
import java.io.IOException;
import java.util.*;

/** TV-only bridge. Reuses the existing player and never writes legacy skip seconds. */
final class TvMarkerHost {
    final MainActivity a;
    final PlaybackControls controls;
    final TvSearchContext context;
    final Cms.Line line;
    final Cms.Episode episode;
    VideoMarkerRepository repository;
    VideoMarkerStore.Document document;
    boolean readFailed, legacyFallback;
    TvMarkerTransaction transaction;
    TvV17MarkerOverlay overlay;
    long openingDownTime = -1;

    TvMarkerHost(MainActivity a, PlaybackControls controls) {
        this.a = a;
        this.controls = controls;
        context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        line = a.activeLine;
        episode = a.activeEpisode;
    }

    boolean valid() {
        return !VideoMarkerRepository.clearing()
                && a.playbackControls == controls
                && a.activeLine == line
                && a.activeEpisode == episode
                && !a.isFinishing()
                && !a.isDestroyed()
                && !a.switchingPrivacy
                && context.matches(a.config, a.privateMode, a.engineEpoch);
    }

    private VideoMarkerStore.Document load() throws IOException {
        if (!valid()) throw new IOException("播放上下文已改变");
        if (repository == null) repository = VideoMarkerRepository.open(a, controls, this::valid);
        if (document == null) document = repository.read();
        return document;
    }

    long effective(boolean intro, long duration, long legacyPosition) {
        if (!valid()) return 0;
        if (legacyFallback) return legacyPosition;
        if (readFailed) return 0;
        try {
            long position =
                    VideoMarkerStore.effective(load().field(repository.identity, intro), duration);
            return position < 0 ? legacyPosition : position;
        } catch (IOException e) {
            readFailed = true;
            a.toast("新标记无法读取，已保留原记录；片头/片尾工具可选择本次使用旧模式");
            return 0;
        }
    }

    boolean canOpen() {
        return valid()
                && a.isTvDevice()
                && !a.isLive()
                && !a.isCast()
                && a.current != null
                && a.current.player
                && !a.miniMode
                && a.prepared
                && a.player != null
                && a.foreground
                && a.hasWindowFocus()
                && !a.controlsVisible
                && a.playbackLoading == null
                && !a.seekGesture.active
                && !controls.isUserSeeking()
                && !controls.transitioning
                && !controls.dialogOpen
                && (a.appDialog == null || !a.appDialog.isShowing());
    }

    boolean open(KeyEvent event) {
        if (event.getAction() != KeyEvent.ACTION_DOWN
                || event.getRepeatCount() != 0
                || event.isCanceled()
                || !canOpen()) return false;
        final MoviePlayer player = a.player;
        final MainActivity.Screen screen = a.current;
        final int generation = a.generation;
        TvMarkerTransaction.Valid owner =
                () ->
                        valid()
                                && a.player == player
                                && a.current == screen
                                && a.generation == generation
                                && a.foreground
                                && a.hasWindowFocus()
                                && a.prepared
                                && !a.miniMode
                                && a.playbackLoading == null
                                && !controls.transitioning
                                && !controls.dialogOpen
                                && (a.appDialog == null || !a.appDialog.isShowing());
        try {
            long revision = load().revision;
            transaction =
                    new TvMarkerTransaction(
                            new TvMarkerTransaction.Player() {
                                public long position() {
                                    return player.getCurrentPosition();
                                }

                                public long duration() {
                                    return player.getDuration();
                                }

                                public boolean playing() {
                                    return player.isPlaying();
                                }

                                public void pause() {
                                    player.pause();
                                    a.playing = false;
                                }

                                public void seek(long position) {
                                    if (position > Integer.MAX_VALUE)
                                        throw new IllegalArgumentException("播放器时间范围不足");
                                    controls.recordUserSeek((int) position);
                                    player.seekTo((int) position);
                                }

                                public void start() {
                                    player.start();
                                    a.playing = true;
                                }
                            },
                            owner);
            openingDownTime = event.getDownTime();
            overlay =
                    new TvV17MarkerOverlay(
                            a,
                            new TvV17MarkerOverlay.Listener() {
                                public void preview(long position) {
                                    try {
                                        transaction.preview(position);
                                    } catch (Exception e) {
                                        abort();
                                        a.toast("预览位置失败，已保持暂停");
                                    }
                                }

                                public void confirm(boolean intro, long position, long duration) {
                                    try {
                                        transaction.confirm(
                                                intro,
                                                position,
                                                (head, selected, observed) -> {
                                                    repository.write(
                                                            revision,
                                                            head,
                                                            new VideoMarkerStore.Field(
                                                                    VideoMarkerStore.NODE,
                                                                    selected,
                                                                    observed));
                                                    document = repository.read();
                                                    controls.refreshMarkerPlaybackMode();
                                                });
                                        a.toast(
                                                repository.persistent
                                                        ? "已保存本集本线路标记"
                                                        : "已记录标记，仅当前会话有效");
                                        remove();
                                    } catch (Exception failure) {
                                        if (transaction != null && transaction.closed) {
                                            remove();
                                            a.toast("标记已保存，播放恢复失败，请手动继续");
                                            return;
                                        }
                                        if (overlay != null)
                                            overlay.failed("保存失败：" + failure.getMessage());
                                    }
                                }

                                public void cancel() {
                                    TvMarkerHost.this.cancel();
                                }
                            });
            a.markerHost = this;
            a.root.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
            overlay.frozen(transaction.entry, transaction.duration);
            overlay.scopeLabel(repository.persistent);
            overlay.requestFocus();
            return true;
        } catch (Exception failure) {
            abort();
            a.toast("暂不能标记，原记录已保留；请从片头/片尾工具查看状态");
            return true;
        }
    }

    boolean key(KeyEvent event) {
        if (overlay == null) return false;
        if (!valid()) {
            abort();
            return true;
        }
        if (event.getKeyCode() == KeyEvent.KEYCODE_DPAD_UP
                && event.getDownTime() == openingDownTime)
            return true; // Opening key/repeats/release belong to the opening gesture only.
        int key = event.getKeyCode();
        if (key == KeyEvent.KEYCODE_VOLUME_UP
                || key == KeyEvent.KEYCODE_VOLUME_DOWN
                || key == KeyEvent.KEYCODE_VOLUME_MUTE
                || key == KeyEvent.KEYCODE_HOME) return false;
        overlay.handleKey(event);
        return true;
    }

    void cancel() {
        try {
            if (transaction != null) transaction.cancel();
        } catch (Exception failure) {
            a.toast("已取消标记，播放恢复失败，请手动继续");
        } finally {
            remove();
        }
    }

    void abort() {
        if (transaction != null) transaction.abort();
        remove();
    }

    private void remove() {
        if (overlay != null && overlay.getParent() instanceof android.view.ViewGroup)
            ((android.view.ViewGroup) overlay.getParent()).removeView(overlay);
        overlay = null;
        transaction = null;
        if (a.markerHost == this) a.markerHost = null;
        if (valid() && a.foreground && a.hasWindowFocus() && a.current != null && a.current.player)
            a.root.requestFocus();
    }

    /**
     * Clears any per-episode v2 node/disabled override back to INHERIT so newly saved per-video
     * intro/outro skip seconds take effect immediately on the current episode as well.
     */
    void inheritLegacy(boolean intro) {
        if (!valid()) return;
        try {
            VideoMarkerStore.Document snapshot = load();
            VideoMarkerStore.Field field = snapshot.field(repository.identity, intro);
            if (field.mode != VideoMarkerStore.INHERIT) {
                repository.write(snapshot.revision, intro, VideoMarkerStore.Field.inherit());
                document = repository.read();
            }
            legacyFallback = false;
            readFailed = false;
        } catch (Throwable ignored) {
            legacyFallback = true;
        }
        controls.refreshMarkerPlaybackMode();
    }

    void manage(boolean intro) {
        if (!valid()) return;
        final VideoMarkerStore.Document snapshot;
        try {
            snapshot = load();
        } catch (IOException error) {
            new AppDialog.Builder(a)
                    .setTitle("标记记录无法读取")
                    .setMessage("原文件保留，未用空数据覆盖。可仅在本次播放使用旧的剩余秒数记录。")
                    .setPositiveButton(
                            "本次使用旧模式",
                            (d, w) -> {
                                if (valid()) {
                                    legacyFallback = true;
                                    controls.refreshMarkerPlaybackMode();
                                }
                            })
                    .setNegativeButton("关闭", null)
                    .show();
            return;
        }
        VideoMarkerStore.Field field = snapshot.field(repository.identity, intro);
        long duration = a.player == null ? 0 : a.player.getDuration();
        String mode =
                field.mode == VideoMarkerStore.NODE
                        ? "绝对节点 " + field.position + " 毫秒"
                        : field.mode == VideoMarkerStore.DISABLED
                                ? "已禁用，不使用旧值"
                                : "旧来源记录，待确认 · "
                                        + (intro
                                                ? "片头 "
                                                        + PlaybackControls.getVideoIntro(
                                                                a, controls.site, controls.video)
                                                : "结束前 "
                                                        + PlaybackControls.getVideoOutro(
                                                                a, controls.site, controls.video))
                                        + " 秒";
        List<String> choices = new ArrayList<>();
        choices.add("旧" + (intro ? "片头持续秒数" : "片尾剩余秒数") + "微调…");
        choices.add("禁用此字段（旧记录不回流）");
        choices.add("恢复使用旧字段（旧数据不改）");
        boolean confirmDuration =
                field.mode == VideoMarkerStore.NODE
                        && duration > field.position
                        && field.automaticPosition(duration) == 0;
        if (confirmDuration) choices.add("确认此节点适用于当前时长");
        new AppDialog.Builder(a)
                .setTitle(
                        (intro ? "片头" : "片尾")
                                + " · "
                                + mode
                                + (repository.persistent ? " · 仅存本机" : " · 当前会话"))
                .setItems(
                        choices.toArray(new String[0]),
                        (d, w) -> {
                            if (!valid()) return;
                            if (w == 0) {
                                a.toast("旧记录仍为秒；如需生效，请选择恢复使用旧字段");
                                PlaybackControls.showSkipAdjuster(
                                        a,
                                        controls.site,
                                        controls.video,
                                        intro,
                                        a.player == null ? 0 : a.player.getCurrentPosition(),
                                        a.player == null ? 0 : a.player.getDuration(),
                                        controls::updateLabels);
                            } else
                                try {
                                    VideoMarkerStore.Field next =
                                            w == 1
                                                    ? new VideoMarkerStore.Field(
                                                            VideoMarkerStore.DISABLED, 0, 0)
                                                    : w == 2
                                                            ? VideoMarkerStore.Field.inherit()
                                                            : new VideoMarkerStore.Field(
                                                                    VideoMarkerStore.NODE,
                                                                    field.position,
                                                                    duration);
                                    repository.write(snapshot.revision, intro, next);
                                    document = repository.read();
                                    legacyFallback = readFailed = false;
                                    controls.refreshMarkerPlaybackMode();
                                    controls.updateLabels();
                                } catch (Exception failure) {
                                    a.notice("未更改标记：" + failure.getMessage());
                                }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }
}
