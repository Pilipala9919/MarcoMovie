package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.*;
import org.json.*;

/** Schema 2 is a sidecar. Legacy intro/outro seconds are never rewritten by this class. */
final class VideoMarkerStore {
    static final int MAX_RECORDS = 500;
    static final int INHERIT = 0, NODE = 1, DISABLED = 2;

    static final class Identity {
        final String scope, config, site, video, episode, line;

        Identity(
                String scope,
                String config,
                String site,
                String video,
                String episode,
                String line) {
            if (!Arrays.asList("public", "private", "session").contains(scope))
                throw new IllegalArgumentException("scope");
            for (String s : new String[] {config, site, video, episode, line})
                if (s == null || !s.matches("[a-f0-9]{64}"))
                    throw new IllegalArgumentException("identity");
            this.scope = scope;
            this.config = config;
            this.site = site;
            this.video = video;
            this.episode = episode;
            this.line = line;
        }

        String key() {
            return scope + config + site + video + episode + line;
        }
    }

    static final class Field {
        final int mode;
        final long position, duration;

        Field(int mode, long position, long duration) {
            if (mode < INHERIT
                    || mode > DISABLED
                    || position < 0
                    || duration < 0
                    || mode == NODE && (position == 0 || duration > 0 && position >= duration)
                    || mode != NODE && (position != 0 || duration != 0))
                throw new IllegalArgumentException("marker range");
            this.mode = mode;
            this.position = position;
            this.duration = duration;
        }

        static Field inherit() {
            return new Field(INHERIT, 0, 0);
        }

        /** Unknown/changed media duration never silently enables an absolute automatic jump. */
        long automaticPosition(long currentDuration) {
            if (mode != NODE || duration <= 0 || currentDuration <= position) return 0;
            long delta =
                    currentDuration >= duration
                            ? currentDuration - duration
                            : duration - currentDuration;
            return delta <= Math.max(2000L, duration / 100) ? position : 0;
        }
    }

    static final class Record {
        final Identity identity;
        final Field intro, outro;

        Record(Identity id, Field intro, Field outro) {
            identity = id;
            this.intro = intro;
            this.outro = outro;
        }

        Field field(boolean head) {
            return head ? intro : outro;
        }
    }

    static final class Document {
        final long revision;
        final Map<String, Record> records;

        Document(long revision, Map<String, Record> records) {
            this.revision = revision;
            this.records = Collections.unmodifiableMap(records);
        }

        Field field(Identity id, boolean intro) {
            Record r = records.get(id.key());
            return r == null ? Field.inherit() : r.field(intro);
        }
    }

    private static long number(JSONObject o, String key) throws Exception {
        Object value = o.get(key);
        if (!(value instanceof Integer) && !(value instanceof Long))
            throw new IOException("integer required");
        long n = ((Number) value).longValue();
        if (n < 0) throw new IOException("negative value");
        return n;
    }

    private static Field field(JSONObject o, String name) throws Exception {
        JSONObject f = o.getJSONObject(name);
        long mode = number(f, "mode");
        if (mode > DISABLED) throw new IOException("unknown mode");
        return new Field((int) mode, number(f, "positionMs"), number(f, "durationMs"));
    }

    static Document read(String raw) throws IOException {
        if (raw == null || raw.isEmpty()) return new Document(0, new LinkedHashMap<>());
        try {
            JSONObject o = new JSONObject(raw);
            if (number(o, "schema") != 2) throw new IOException("unsupported schema");
            long revision = number(o, "revision");
            JSONArray array = o.getJSONArray("records");
            if (array.length() > MAX_RECORDS) throw new IOException("record limit");
            Map<String, Record> records = new LinkedHashMap<>();
            for (int i = 0; i < array.length(); i++) {
                JSONObject r = array.getJSONObject(i);
                Identity id =
                        new Identity(
                                r.getString("scope"),
                                r.getString("configId"),
                                r.getString("siteId"),
                                r.getString("videoId"),
                                r.getString("episodeId"),
                                r.getString("lineId"));
                Record record = new Record(id, field(r, "intro"), field(r, "outro"));
                if (records.put(id.key(), record) != null)
                    throw new IOException("duplicate identity");
            }
            return new Document(revision, records);
        } catch (Exception invalid) {
            throw new IOException("标记记录无法读取，原数据已保留", invalid);
        }
    }

    static String update(String raw, long expectedRevision, Identity id, boolean intro, Field value)
            throws IOException {
        Document old = read(raw);
        if (old.revision != expectedRevision) throw new IOException("标记已更改，请重新打开后再保存");
        if (old.revision == Long.MAX_VALUE) throw new IOException("标记版本已达上限");
        Map<String, Record> records = new LinkedHashMap<>(old.records);
        Record before = records.get(id.key());
        if (before == null && records.size() >= MAX_RECORDS)
            throw new IOException("标记已满500条；未淘汰旧记录或禁用状态");
        records.put(
                id.key(),
                new Record(
                        id,
                        intro ? value : before == null ? Field.inherit() : before.intro,
                        intro ? before == null ? Field.inherit() : before.outro : value));
        try {
            JSONArray list = new JSONArray();
            for (Record record : records.values()) {
                Identity k = record.identity;
                list.put(
                        new JSONObject()
                                .put("scope", k.scope)
                                .put("configId", k.config)
                                .put("siteId", k.site)
                                .put("videoId", k.video)
                                .put("episodeId", k.episode)
                                .put("lineId", k.line)
                                .put("intro", json(record.intro))
                                .put("outro", json(record.outro)));
            }
            return new JSONObject()
                    .put("schema", 2)
                    .put("revision", old.revision + 1)
                    .put("records", list)
                    .toString();
        } catch (JSONException e) {
            throw new IOException(e);
        }
    }

    private static JSONObject json(Field field) throws JSONException {
        return new JSONObject()
                .put("mode", field.mode)
                .put("positionMs", field.position)
                .put("durationMs", field.duration);
    }

    /** -1 means legacy semantics; zero means explicitly disabled or not yet confirmed. */
    static long effective(Field field, long duration) {
        return field.mode == INHERIT ? -1 : field.automaticPosition(duration);
    }
}
