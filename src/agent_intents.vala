namespace Singularity.Apps.Radio {

    internal class RadioIntents : Object {
        private static Gee.HashMap<string, Station> seen = null;

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string state_id(PlayState s) {
            switch (s) {
                case PlayState.CONNECTING: return "connecting";
                case PlayState.BUFFERING: return "buffering";
                case PlayState.PLAYING: return "playing";
                case PlayState.PAUSED: return "paused";
                case PlayState.FAILED: return "failed";
                default: return "stopped";
            }
        }

        private static void remember(Station s) {
            if (seen == null) seen = new Gee.HashMap<string, Station>();
            seen[s.key()] = s;
        }

        private static void station(Json.Builder b, RadioApp app, Station s) {
            remember(s);
            b.begin_object();
            b.set_member_name("id").add_string_value(s.key());
            b.set_member_name("name").add_string_value(s.name.strip());
            string place = s.location();
            if (place != "") b.set_member_name("place").add_string_value(place);
            var tags = s.tag_list(5);
            if (tags.length > 0) {
                b.set_member_name("tags").begin_array();
                foreach (string t in tags) b.add_string_value(t);
                b.end_array();
            }
            string q = s.format_quality();
            if (q != "") b.set_member_name("quality").add_string_value(q);
            if (app.library.is_favorite(s)) b.set_member_name("favorite").add_boolean_value(true);
            b.end_object();
        }

        private static Station find(RadioApp app, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT("give the station id or name from radio_search or radio_favorites");
            var s = app.library.find(wanted);
            if (s != null) return s;
            if (seen != null && seen.has_key(wanted)) return seen[wanted];
            string w = wanted.casefold();
            var pools = new Gee.ArrayList<Station>();
            pools.add_all(app.library.favorites);
            pools.add_all(app.library.recent);
            if (seen != null) pools.add_all(seen.values);
            foreach (var x in pools) if (x.name.strip().casefold() == w) return x;
            foreach (var x in pools) if (x.name.casefold().contains(w)) return x;
            throw new IOError.NOT_FOUND("no station %s among favorites, recent or searched; use radio_search first", wanted);
        }

        private static void now(Json.Builder b, RadioApp app) {
            var p = app.player;
            b.set_member_name("state").add_string_value(state_id(p.state));
            if (p.station != null) b.set_member_name("station").add_string_value(p.station.name.strip());
            if (p.now_playing != "") b.set_member_name("now_playing").add_string_value(p.now_playing);
            if (p.state == PlayState.FAILED && p.failure != "") b.set_member_name("error").add_string_value(p.failure);
            b.set_member_name("volume_percent").add_int_value((int64) Math.round(p.volume * 100));
            if (p.muted) b.set_member_name("muted").add_boolean_value(true);
            if (app.sleep.active) b.set_member_name("sleep_in_seconds").add_int_value(app.sleep.remaining());
        }

        private static async void wait(uint ms) {
            Timeout.add(ms, wait.callback);
            yield;
        }

        private static async void search(RadioApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                if (!Directory.online()) throw new IOError.NETWORK_UNREACHABLE("the computer is offline");
                var q = new Query();
                q.name = text(args, "name");
                q.tag = text(args, "genre");
                q.country = text(args, "country");
                q.language = text(args, "language");
                q.limit = args.has_member("limit") ? (int) args.get_int_member("limit").clamp(1, 50) : 10;
                if (q.is_empty()) throw new IOError.INVALID_ARGUMENT("give a name, genre, country or language");
                var found = yield app.directory.search(q, null);
                var b = new Json.Builder();
                b.begin_array();
                foreach (var s in found) station(b, app, s);
                b.end_array();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void play(RadioApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                Station s;
                if (text(args, "station") == "") {
                    if (app.library.recent.size > 0) s = app.library.recent[0];
                    else if (app.library.favorites.size > 0) s = app.library.favorites[0];
                    else throw new IOError.NOT_FOUND("nothing played before; name a station");
                } else {
                    s = find(app, text(args, "station"));
                }
                app.play_in_background(s);
                for (int i = 0; i < 60; i++) {
                    var st = app.player.state;
                    if (st == PlayState.PLAYING || st == PlayState.FAILED) break;
                    yield wait(250);
                }
                var b = new Json.Builder();
                b.begin_object();
                now(b, app);
                if (app.player.state != PlayState.PLAYING) b.set_member_name("verified").add_boolean_value(false);
                b.set_member_name("undo").add_string_value("radio_control with action stop");
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        internal static void install(RadioApp app) {
            var agent = app.agent;
            agent.add_async_intent("radio_search", "Find internet radio stations by name, genre, country or language, most listened first.",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"genre\":{\"type\":\"string\"},\"country\":{\"type\":\"string\"},\"language\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    search.begin(app, args, (owned) reply);
                });
            agent.add_intent("radio_favorites", "The favorite stations and the ones played recently.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("favorites").begin_array();
                    foreach (var s in app.library.favorites) station(b, app, s);
                    b.end_array();
                    b.set_member_name("recent").begin_array();
                    int n = 0;
                    foreach (var s in app.library.recent) {
                        if (n++ == 10) break;
                        station(b, app, s);
                    }
                    b.end_array();
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("radio_now_playing", "What Radio is playing now, the song title when the station sends it, and the volume.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_object();
                    now(b, app);
                    b.end_object();
                    return b.get_root();
                });
            agent.add_async_intent("radio_play", "Play a station by id or name (the last one when left out). It keeps playing without a window.",
                "{\"type\":\"object\",\"properties\":{\"station\":{\"type\":\"string\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    play.begin(app, args, (owned) reply);
                });
            agent.add_intent("radio_control", "Pause, resume, stop, go to the next or previous favorite, or set the volume (0 to 100).",
                "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"pause\",\"resume\",\"stop\",\"next\",\"previous\",\"mute\",\"unmute\"]},\"volume\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string action = text(args, "action");
                    double before = app.player.volume;
                    if (args.has_member("volume")) app.player.volume = args.get_int_member("volume").clamp(0, 100) / 100.0;
                    switch (action) {
                        case "": break;
                        case "pause": app.player.pause(); break;
                        case "resume": app.resume(); break;
                        case "stop": app.player.stop(); break;
                        case "next": app.step_station(1); break;
                        case "previous": app.step_station(-1); break;
                        case "mute": app.player.muted = true; break;
                        case "unmute": app.player.muted = false; break;
                        default: throw new IOError.INVALID_ARGUMENT("unknown action %s", action);
                    }
                    if (action == "" && !args.has_member("volume")) throw new IOError.INVALID_ARGUMENT("give an action or a volume");
                    var b = new Json.Builder();
                    b.begin_object();
                    now(b, app);
                    if (args.has_member("volume")) b.set_member_name("undo").add_string_value("radio_control with volume %d".printf((int) Math.round(before * 100)));
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("radio_favorite", "Add a station to the favorites, or remove it with favorite false.",
                "{\"type\":\"object\",\"properties\":{\"station\":{\"type\":\"string\"},\"favorite\":{\"type\":\"boolean\"}},\"required\":[\"station\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var s = find(app, text(args, "station"));
                    bool want = !args.has_member("favorite") || args.get_boolean_member("favorite");
                    if (want) app.library.add_favorite(s);
                    else app.library.remove_favorite(s);
                    var fresh = new Library();
                    bool stored = false;
                    foreach (var x in fresh.favorites) if (x.key() == s.key()) stored = true;
                    if (stored != want) throw new IOError.FAILED("the favorites were not saved");
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("station").add_string_value(s.name.strip());
                    b.set_member_name("favorite").add_boolean_value(want);
                    b.set_member_name("undo").add_string_value("radio_favorite with favorite %s".printf(want ? "false" : "true"));
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("radio_sleep", "Stop the radio after some minutes, fading out; 0 cancels the sleep timer.",
                "{\"type\":\"object\",\"properties\":{\"minutes\":{\"type\":\"integer\"}},\"required\":[\"minutes\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    int minutes = (int) args.get_int_member("minutes").clamp(0, 600);
                    if (minutes == 0) app.sleep.cancel();
                    else app.sleep.start_minutes(minutes);
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("sleep_timer").add_boolean_value(app.sleep.active);
                    if (app.sleep.active) b.set_member_name("stops_in_seconds").add_int_value(app.sleep.remaining());
                    b.set_member_name("undo").add_string_value(minutes == 0 ? "radio_sleep with the earlier minutes" : "radio_sleep with minutes 0");
                    b.end_object();
                    return b.get_root();
                });
        }
    }
}
