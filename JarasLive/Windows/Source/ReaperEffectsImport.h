// Included after RppChunk: import policy mirrors ReaperProjectImporter.swift.
// Plugin resolution is injectable; third-party code stays in the probe process.
struct RppEffects {
    var settings;
    Array<var> envelopes;
};
inline double rppNumeric(const String &text) {
    const auto raw = utf8(text);
    char *end = nullptr;
    const auto n = std::strtod(raw.c_str(), &end);
    require(end != raw.c_str() && *end == 0 && std::isfinite(n), migration::message("REAPER: invalid numeric value."));
    return n;
}
inline var rppEnvelope(const RppChunk &node, const var &target, const String &name,
                       StringArray &warnings, const String &scope) {
    if (!node.line("POOLEDENVINST").isEmpty() || node.child("POOLEDENVINST") || node.child("AI"))
        warnings.addIfNotAlreadyThere(
            scope + ": " + name +
            migration::message(" contains automation items; pooled automation items were not imported."));
    struct Point {
        double time, value, tension;
        int shape;
    };
    std::vector<Point> points;
    for (const auto &row : node.lines)
        if (row[0] == "PT")
            try {
                require(row.size() >= 3, migration::message("REAPER: invalid envelope point."));
                const double shape = row.size() > 3 ? rppNumeric(row[3]) : 0;
                require(shape == std::floor(shape) && shape >= 0 && shape <= 5,
                        migration::message("REAPER: invalid envelope point shape."));
                Point p{rppNumeric(row[1]), rppNumeric(row[2]), row.size() > 7 ? rppNumeric(row[7]) : 0,
                        (int)shape};
                if (!points.empty() && points.back().time == p.time)
                    points.back() = p;
                else
                    points.push_back(p);
            } catch (const std::exception &e) {
                warnings.addIfNotAlreadyThere(migration::message("REAPER envelope point ignored: ") +
                                              String::fromUTF8(e.what()));
            }
    if (points.empty())
        return {};
    for (size_t i = 1; i < points.size(); ++i)
        require(points[i - 1].time < points[i].time, migration::message("REAPER: unsorted envelope points."));
    const auto kind = str(target, "kind");
    const bool volume = kind == "volume", fader = volume && node.number("VOLTYPE") == 1;
    const double maximum = volume ? std::pow(10., .6) : 1., minimum = kind == "pan" ? -1. : 0.;
    for (const auto &p : points)
        if (p.value < minimum || p.value > maximum) {
            warnings.addIfNotAlreadyThere(
                scope + ": " + name +
                migration::message(" envelope exceeds the CatLive parameter range and was not applied."));
            return {};
        }
    const auto normalize = [&](double v) {
        return volume           ? AutomationCurve::normalized(v)
               : kind == "pan"  ? (v + 1) * .5
               : kind == "mute" ? 1 - v
                                : v;
    };
    auto result = object();
    put(result, "id", text(uuid()));
    put(result, "target", target);
    put(result, "name", name);
    put(result, "enabled", node.number("ACT", 1, 1) != 0);
    put(result, "visible", node.number("VIS", 1, 1) != 0);
    put(result, "armed", node.number("ARM") != 0);
    put(result, "defaultValue",
        volume           ? normalize(1)
        : kind == "pan"  ? .5
        : kind == "mute" ? 0
                         : points.front().value);
    if (volume)
        put(result, "valueScale", "linearGain");
    static const char *shapes[] = {"linear", "square", "smooth", "fastStart", "fastEnd"};
    const auto interpolate = [](int shape, double x) {
        return shape == 1   ? 0.
               : shape == 2 ? x * x * (3 - 2 * x)
               : shape == 3 ? 1 - std::pow(1 - x, 3)
               : shape == 4 ? x * x * x
                            : x;
    };
    const double faderGain = maximum / 2;
    const auto domain = [&](double v) {
        return fader ? std::pow((std::sqrt(1 + 4 * v / faderGain) - 1) / 2, 1. / 3) : v;
    };
    const auto cubic = [](double t, double a, double b, double c, double d) {
        const auto u = 1 - t;
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
    };
    const auto rawValue = [&](size_t i, double fraction) {
        const auto &a = points[i], &b = points[i + 1];
        const double av = domain(a.value), bv = domain(b.value);
        double value = 0;
        if (a.shape < 5)
            value = av + (bv - av) * interpolate(a.shape, fraction);
        else {
            const auto &previous = i ? points[i - 1] : a,
                       &next = i + 2 < points.size() ? points[i + 2] : b;
            const double span = b.time - a.time, t = std::clamp(a.tension, -1., 1.);
            double x1 = .25, x2 = .75,
                   y1 = av + (bv - domain(previous.value)) / (b.time - previous.time) * span * .25,
                   y2 = bv - (domain(next.value) - av) / (next.time - a.time) * span * .25;
            x1 += t * (t > 0 ? 1 - x1 : x1);
            x2 += t * (t > 0 ? 1 - x2 : x2);
            y1 -= t * (t > 0 ? y1 - av : bv - y1);
            y2 -= t * (t > 0 ? y2 - av : bv - y2);
            y1 = std::clamp(y1, domain(minimum), domain(maximum));
            y2 = std::clamp(y2, domain(minimum), domain(maximum));
            double low = 0, high = 1;
            for (int n = 0; n < 36; ++n) {
                const double mid = (low + high) * .5;
                if (cubic(mid, 0, x1, x2, 1) < fraction)
                    low = mid;
                else
                    high = mid;
            }
            value = cubic((low + high) * .5, av, y1, y2, bv);
        }
        const double q = value * value * value;
        return fader ? faderGain * q * (1 + q) : value;
    };
    Array<var> imported;
    const auto append = [&](double time, double value, const char *shape) {
        auto p = object();
        put(p, "id", text(uuid()));
        put(p, "time", time);
        put(p, "value", normalize(value));
        put(p, "shape", shape);
        imported.add(p);
    };
    for (size_t i = 0; i < points.size(); ++i) {
        const auto &a = points[i];
        const bool sample = i + 1 < points.size() && a.shape != 1 && (fader || a.shape == 5);
        append(a.time, a.value, sample ? "linear" : shapes[std::min(4, a.shape)]);
        if (!sample)
            continue;
        const auto &b = points[i + 1];
        std::function<void(double, double, double, double, int)> refine =
            [&](double first, double fv, double last, double lv, int depth) {
                double error = 0;
                for (const double w : {.25, .5, .75})
                    error = std::max(
                        error, std::abs(rawValue(i, first + (last - first) * w) - (fv + (lv - fv) * w)));
                if (error > .00001 && depth < 16 && (last - first) * (b.time - a.time) > .000001) {
                    const double mid = (first + last) * .5, mv = rawValue(i, mid);
                    refine(first, fv, mid, mv, depth + 1);
                    append(a.time + (b.time - a.time) * mid, mv, "linear");
                    require(imported.size() < 200000,
                            migration::message("REAPER: envelope contains too many resampled points."));
                    refine(mid, mv, last, lv, depth + 1);
                }
            };
        refine(0, a.value, 1, b.value, 0);
    }
    put(result, "points", imported);
    return result;
}
inline var rppAutomation(const RppChunk &node, Array<var> envelopes, bool take, double offset,
                         StringArray &warnings, const String &scope) {
    int mode = 0;
    try {
        const auto raw = node.number("AUTOMODE");
        require(raw == std::floor(raw) && raw >= INT_MIN && raw <= INT_MAX,
                migration::message("REAPER: invalid automation mode."));
        mode = (int)raw;
    } catch (const std::exception &e) {
        warnings.addIfNotAlreadyThere(migration::message("REAPER automation mode ignored: ") + String::fromUTF8(e.what()));
    }
    static const char *modes[] = {"trimRead", "read", "touch", "write", "latch"};
    if (mode > 4)
        warnings.addIfNotAlreadyThere(scope +
                                      migration::message(": unsupported REAPER automation mode was imported as Read."));
    for (const auto &owned : node.children)
        try {
            const auto &child = *owned;
            const auto key = child.header[0];
            String kind;
            if (key == (take ? "VOLENV" : "VOLENV2"))
                kind = "volume";
            else if (key == (take ? "PANENV" : "PANENV2"))
                kind = "pan";
            else if (key == "MUTEENV")
                kind = "mute";
            if (kind.isNotEmpty()) {
                auto target = object();
                put(target, "kind", kind);
                auto envelope = rppEnvelope(child, target, kind, warnings, scope);
                if (envelope.isObject())
                    envelopes.add(envelope);
            } else if (key.contains("ENV") && key != "PARMENV" && key != "TEMPOENVEX") {
                int count = 0;
                for (const auto &row : child.lines)
                    count += row[0] == "PT";
                if (count)
                    warnings.addIfNotAlreadyThere(scope + ": REAPER " + key +
                                                  migration::message(" automation is not supported and was not applied."));
            }
        } catch (const std::exception &e) {
            warnings.addIfNotAlreadyThere(migration::message("REAPER envelope ignored: ") + String::fromUTF8(e.what()));
        }
    if (envelopes.isEmpty())
        return {};
    for (auto &envelope : envelopes) {
        auto values = list(get(envelope, "points"));
        for (auto &p : values)
            put(p, "time", num(p, "time") + offset);
        if (!values.isEmpty() && num(values[0], "time") < 0) {
            AutomationCurve curve;
            curve.fallback = num(envelope, "defaultValue");
            curve.linearGain = str(envelope, "valueScale") == "linearGain";
            for (const auto &p : values) {
                const auto shape = str(p, "shape");
                curve.points.push_back({num(p, "time"), num(p, "value"),
                                        shape == "square"      ? AutomationCurve::square
                                        : shape == "smooth"    ? AutomationCurve::smooth
                                        : shape == "fastStart" ? AutomationCurve::fastStart
                                        : shape == "fastEnd"   ? AutomationCurve::fastEnd
                                                               : AutomationCurve::linear});
            }
            const auto boundary = curve.value(0);
            while (!values.isEmpty() && num(values[0], "time") < 0)
                values.remove(0);
            if (values.isEmpty() || num(values[0], "time") != 0) {
                auto p = object();
                put(p, "id", text(uuid()));
                put(p, "time", 0.);
                put(p, "value", boundary);
                put(p, "shape", "linear");
                values.insert(0, p);
            }
        }
        put(envelope, "points", values);
        if (!take && flag(envelope, "enabled", true))
            put(envelope, "visible", true);
    }
    auto result = object();
    put(result, "enabled", true);
    put(result, "mode", mode >= 0 && mode <= 4 ? modes[mode] : "read");
    put(result, "lanesVisible", true);
    put(result, "envelopes", envelopes);
    return result;
}
inline std::pair<String, String> rppVST3States(const StringArray &lines) {
    if (lines.isEmpty())
        return {};
    MemoryOutputStream joined;
    for (const auto &line : lines) {
        MemoryOutputStream decoded;
        require(Base64::convertFromBase64(decoded, line), migration::message("REAPER: invalid VST3 state encoding."));
        require(joined.getDataSize() + decoded.getDataSize() <= 64 * 1024 * 1024,
                migration::message("REAPER: VST3 state too large."));
        joined.write(decoded.getData(), decoded.getDataSize());
    }
    const auto *data = (const uint8 *)joined.getData();
    const auto size = joined.getDataSize();
    const auto u32 = [&](size_t at) -> uint32 {
        require(at <= size && size - at >= 4, migration::message("REAPER: truncated VST3 state."));
        return ByteOrder::littleEndianInt(data + at);
    };
    require(u32(4) == 0xfeed5eee, migration::message("REAPER: unsupported VST3 routing-state format."));
    const auto inputs = u32(8);
    require(inputs <= 4096, migration::message("REAPER: invalid VST3 input count."));
    const size_t output = 12 + 8 * size_t(inputs);
    const auto outputs = u32(output);
    require(outputs <= 4096, migration::message("REAPER: invalid VST3 output count."));
    const size_t lengthOffset = output + 4 + 8 * size_t(outputs);
    const auto length = u32(lengthOffset);
    size_t cursor = lengthOffset + 12;
    require(length <= 64 * 1024 * 1024 && cursor <= size && length <= size - cursor,
            migration::message("REAPER: truncated VST3 processor state."));
    const size_t end = cursor + length;
    String component, controller;
    bool haveComponent = false, haveController = false;
    while (cursor < end) {
        const auto count = u32(cursor), kind = u32(cursor + 4);
        cursor += 8;
        require(cursor <= end && count <= end - cursor && kind <= 1,
                migration::message("REAPER: unsupported VST3 state record."));
        if (count) {
            auto &have = kind == 1 ? haveComponent : haveController;
            require(!have, migration::message("REAPER: duplicate VST3 state."));
            have = true;
            (kind == 1 ? component : controller) = Base64::toBase64(data + cursor, count);
        }
        cursor += count;
    }
    return {component, controller};
}
inline RppEffects rppImportFX(const RppChunk *chain, const ReaperVST3Resolver &resolve,
                              StringArray &warnings, const String &scope) {
    RppEffects result;
    if (!chain)
        return result;
    auto settings = object();
    Array<var> plugins, inserted;
    for (const auto &owned : chain->children) {
        const auto &node = *owned;
        const auto &h = node.header;
        const auto type = h[0];
        if (type == "CONTAINER") {
            warnings.addIfNotAlreadyThere(scope + migration::message(": REAPER FX containers are not supported; effects inside containers were not imported."));
            continue;
        }
        if (type != "VST" && type != "AU" && type != "JS" && type != "DX" && type != "CLAP" &&
            type != "VIDEO_EFFECT")
            continue;
        try {
            require(type == "VST" && h.size() > 5 &&
                        (h[1].startsWith("VST3:") || h[1].startsWith("VST3i:")),
                    scope + migration::message(": only VST3 effects are supported during REAPER migration."));
            const int open = h[5].indexOfChar('{'), close = h[5].indexOfChar('}');
            require(open >= 0 && close > open, migration::message("REAPER: VST3 has no class ID."));
            const auto classID = h[5].substring(open + 1, close).toUpperCase();
            require(classID.length() == 32 && classID.containsOnly("0123456789ABCDEF"),
                    migration::message("REAPER: invalid VST3 class ID."));
            auto plugin = object();
            const auto id = text(uuid()), name = h[1].fromFirstOccurrenceOf(":", false, false).trim();
            put(plugin, "id", id);
            put(plugin, "classID", classID);
            put(plugin, "name", name);
            put(plugin, "path", h[2]);
            put(plugin, "category", h[1].startsWith("VST3i:") ? "Instrument" : "Fx");
            put(plugin, "bypassed", node.effectBypass[1] == "1" || node.effectBypass[2] == "1");
            bool validState = true, available = false;
            try {
                const auto states = rppVST3States(node.notes);
                if (states.first.isNotEmpty())
                    put(plugin, "componentState", states.first);
                if (states.second.isNotEmpty())
                    put(plugin, "controllerState", states.second);
            } catch (const std::exception &e) {
                validState = false;
                put(plugin, "bypassed", true);
                warnings.addIfNotAlreadyThere(scope + ": " + name +
                                              migration::message(" state was not imported: ") + String::fromUTF8(e.what()));
            }
            std::set<int> indices;
            for (const auto *envelope : node.effectEnvelopes) {
                const auto raw = envelope->header[1];
                const int separator = raw.indexOfChar(':');
                const auto indexText = separator < 0 ? raw : raw.substring(0, separator);
                const auto parameterText = separator < 0 ? String() : raw.substring(separator + 1);
                require(indexText.isNotEmpty() && indexText.containsOnly("0123456789") &&
                            (separator < 0 ||
                             (parameterText.isNotEmpty() && parameterText.containsOnly("0123456789"))),
                        migration::message("REAPER: invalid automation parameter identity."));
                const auto index = rppNumeric(indexText);
                require(index <= INT_MAX, migration::message("REAPER: invalid automation parameter index."));
                if (separator >= 0)
                    require(rppNumeric(parameterText) <= UINT32_MAX,
                            migration::message("REAPER: invalid automation parameter ID."));
                indices.insert((int)index);
            }
            var resolved;
            if (resolve)
                try {
                    resolved = resolve(plugin, indices);
                    if (resolved.isObject()) {
                        require(str(resolved, "classID").equalsIgnoreCase(classID),
                                migration::message("REAPER: resolver returned a different plugin class."));
                        put(plugin, "path", str(resolved, "path"));
                        put(plugin, "category", str(resolved, "category"));
                        available = validState;
                    }
                } catch (const std::exception &e) {
                    warnings.addIfNotAlreadyThere(
                        scope + ": " + name + migration::message(" could not be restored: ") + String::fromUTF8(e.what()));
                }
            if (!available) {
                put(plugin, "bypassed", true);
                warnings.addIfNotAlreadyThere(scope + ": VST3 " + name +
                                              migration::message(" was not found or restored. Its saved state was retained, but the effect was not inserted."));
            }
            if (str(plugin, "category").containsIgnoreCase("midi"))
                warnings.addIfNotAlreadyThere(
                    scope + ": " + name +
                    migration::message(" is categorized as a MIDI effect; VST3 MIDI-output transformations are not supported and were not migrated."));
            plugins.add(plugin);
            if (available)
                inserted.add("External:" + id);
            for (const auto *envelope : node.effectEnvelopes)
                try {
                    const auto identity = StringArray::fromTokens(envelope->header[1], ":", "");
                    var parameter;
                    if (identity.size() == 2) {
                        const double n = rppNumeric(identity[1]);
                        require(n >= 0 && n <= UINT32_MAX && n == std::floor(n),
                                migration::message("REAPER: invalid parameter ID."));
                        parameter = (int64)n;
                    } else
                        parameter = get(get(resolved, "parameterIDs"), identity[0]);
                    if (parameter.isVoid()) {
                        warnings.addIfNotAlreadyThere(scope + ": " + name +
                                                      migration::message(" automation parameter could not be identified; the envelope was not applied."));
                        continue;
                    }
                    auto target = object();
                    put(target, "kind", "externalFX");
                    put(target, "plugin", id);
                    put(target, "parameter", parameter);
                    const auto label = envelope->header.size() > 5 ? envelope->header[5]
                                                                   : name + " · " + envelope->header[1];
                    auto imported = rppEnvelope(*envelope, target, label, warnings, scope);
                    if (imported.isObject())
                        result.envelopes.add(imported);
                } catch (const std::exception &e) {
                    warnings.addIfNotAlreadyThere(migration::message("REAPER FX envelope ignored: ") +
                                                  String::fromUTF8(e.what()));
                }
        } catch (const std::exception &e) {
            warnings.addIfNotAlreadyThere(migration::message("REAPER FX ignored: ") + String::fromUTF8(e.what()));
        }
    }
    if (!plugins.isEmpty()) {
        put(settings, "externalPlugins", plugins);
        put(settings, "inserted", inserted);
        result.settings = settings;
    }
    return result;
}
