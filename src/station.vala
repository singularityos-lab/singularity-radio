namespace Singularity.Apps.Radio {

    public class Station : Object {
        public string uuid = "";
        public string name = "";
        public string url = "";
        public string url_resolved = "";
        public string homepage = "";
        public string favicon = "";
        public string tags = "";
        public string country = "";
        public string country_code = "";
        public string state = "";
        public string language = "";
        public string codec = "";
        public int bitrate;
        public int votes;
        public int clicks;
        public bool hls;
        public bool last_check_ok = true;
        public bool custom;

        public string key () {
            return uuid != "" ? uuid : "custom:" + stream_url ();
        }

        public string stream_url () {
            return url_resolved != "" ? url_resolved : url;
        }

        public string[] tag_list (int max = 0) {
            string[] out_v = {};
            foreach (string t in tags.split (",")) {
                string s = t.strip ();
                if (s == "") continue;
                bool seen = false;
                foreach (string o in out_v) if (o.down () == s.down ()) seen = true;
                if (seen) continue;
                out_v += s;
                if (max > 0 && out_v.length >= max) break;
            }
            return out_v;
        }

        public string format_quality () {
            string c = codec.strip ().up ();
            if (c == "UNKNOWN") c = "";
            if (bitrate > 0 && c != "") return "%s %d kbps".printf (c, bitrate);
            if (bitrate > 0) return "%d kbps".printf (bitrate);
            return c;
        }

        public string location () {
            if (state.strip () != "" && country.strip () != "") return "%s, %s".printf (state.strip (), country.strip ());
            return country.strip ();
        }

        public string subtitle () {
            string[] parts = {};
            string[] t = tag_list (3);
            if (t.length > 0) parts += string.joinv (", ", t);
            if (country.strip () != "") parts += country.strip ();
            string q = format_quality ();
            if (q != "") parts += q;
            return string.joinv (" · ", parts);
        }

        public Json.Object to_json () {
            var o = new Json.Object ();
            o.set_string_member ("stationuuid", uuid);
            o.set_string_member ("name", name);
            o.set_string_member ("url", url);
            o.set_string_member ("url_resolved", url_resolved);
            o.set_string_member ("homepage", homepage);
            o.set_string_member ("favicon", favicon);
            o.set_string_member ("tags", tags);
            o.set_string_member ("country", country);
            o.set_string_member ("countrycode", country_code);
            o.set_string_member ("state", state);
            o.set_string_member ("language", language);
            o.set_string_member ("codec", codec);
            o.set_int_member ("bitrate", bitrate);
            o.set_int_member ("votes", votes);
            o.set_int_member ("clickcount", clicks);
            o.set_int_member ("hls", hls ? 1 : 0);
            o.set_boolean_member ("custom", custom);
            return o;
        }

        public static string str (Json.Object o, string member) {
            if (!o.has_member (member)) return "";
            var n = o.get_member (member);
            if (n.get_node_type () != Json.NodeType.VALUE) return "";
            if (n.get_value_type () == typeof (string)) return n.get_string () ?? "";
            if (n.get_value_type () == typeof (int64)) return n.get_int ().to_string ();
            return "";
        }

        private static int num (Json.Object o, string member) {
            if (!o.has_member (member)) return 0;
            var n = o.get_member (member);
            if (n.get_node_type () != Json.NodeType.VALUE) return 0;
            if (n.get_value_type () == typeof (int64)) return (int) n.get_int ();
            if (n.get_value_type () == typeof (double)) return (int) n.get_double ();
            if (n.get_value_type () == typeof (bool)) return n.get_boolean () ? 1 : 0;
            if (n.get_value_type () == typeof (string)) return int.parse (n.get_string () ?? "0");
            return 0;
        }

        public static Station? from_json (Json.Object o) {
            var s = new Station ();
            s.uuid = str (o, "stationuuid").strip ();
            s.name = clean_text (str (o, "name"));
            s.url = str (o, "url").strip ();
            s.url_resolved = str (o, "url_resolved").strip ();
            s.homepage = str (o, "homepage").strip ();
            s.favicon = str (o, "favicon").strip ();
            s.tags = str (o, "tags").strip ();
            s.country = str (o, "country").strip ();
            s.country_code = str (o, "countrycode").strip ().up ();
            s.state = str (o, "state").strip ();
            s.language = str (o, "language").strip ();
            s.codec = str (o, "codec").strip ();
            s.bitrate = int.max (0, num (o, "bitrate"));
            s.votes = int.max (0, num (o, "votes"));
            s.clicks = int.max (0, num (o, "clickcount"));
            s.hls = num (o, "hls") != 0;
            s.last_check_ok = !o.has_member ("lastcheckok") || num (o, "lastcheckok") != 0;
            s.custom = o.has_member ("custom") && o.get_member ("custom").get_value_type () == typeof (bool) && o.get_boolean_member ("custom");
            if (s.stream_url () == "" || !is_stream_url (s.stream_url ())) return null;
            if (s.name == "") s.name = host_of (s.stream_url ());
            return s;
        }

        public static string clean_text (string text) {
            var sb = new StringBuilder ();
            bool space = false;
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                if (c.isspace ()) {
                    space = true;
                    continue;
                }
                if (c.iscntrl () || c == 0xFEFF) continue;
                if (space && sb.len > 0) sb.append_c (' ');
                space = false;
                sb.append_unichar (c);
            }
            return sb.str;
        }

        public static bool is_stream_url (string url) {
            string u = url.strip ().down ();
            return u.has_prefix ("http://") || u.has_prefix ("https://") || u.has_prefix ("rtsp://") || u.has_prefix ("mms://") || u.has_prefix ("rtmp://");
        }

        public static string host_of (string url) {
            try {
                var uri = Uri.parse (url.strip (), UriFlags.NONE);
                return uri.get_host () ?? url;
            } catch (Error e) {
                return url;
            }
        }
    }

    namespace Parse {
        public Gee.List<Station> stations (Json.Node root) {
            var list = new Gee.ArrayList<Station> ();
            if (root.get_node_type () != Json.NodeType.ARRAY) return list;
            var seen = new Gee.HashSet<string> ();
            foreach (var n in root.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var s = Station.from_json (n.get_object ());
                if (s == null || seen.contains (s.key ())) continue;
                seen.add (s.key ());
                list.add (s);
            }
            return list;
        }

        public string[] servers (Json.Node root) {
            string[] names = {};
            if (root.get_node_type () != Json.NodeType.ARRAY) return names;
            foreach (var n in root.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                string name = Station.str (n.get_object (), "name").strip ().down ();
                if (name == "" || !name.has_suffix (".api.radio-browser.info")) continue;
                bool dup = false;
                foreach (string e in names) if (e == name) dup = true;
                if (!dup) names += name;
            }
            return names;
        }

        public class Facet : Object {
            public string name = "";
            public string code = "";
            public int count;
        }

        public Gee.List<Facet> facets (Json.Node root, int min_count = 1) {
            var list = new Gee.ArrayList<Facet> ();
            if (root.get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in root.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = n.get_object ();
                var f = new Facet ();
                f.name = Station.clean_text (Station.str (o, "name"));
                f.code = Station.str (o, "iso_3166_1");
                if (f.code == "") f.code = Station.str (o, "iso_639");
                f.count = int.parse (Station.str (o, "stationcount"));
                if (f.name == "" || f.count < min_count) continue;
                list.add (f);
            }
            return list;
        }

        public string? playlist (string text) {
            string body = text.strip ();
            if (body.has_prefix ("<")) {
                foreach (string attr in new string[] { "href=\"", "href='" }) {
                    int i = body.down ().index_of (attr);
                    while (i >= 0) {
                        int start = i + attr.length;
                        int end = body.index_of_char (attr[attr.length - 1], start);
                        if (end < 0) break;
                        string u = body.substring (start, end - start).replace ("&amp;", "&").strip ();
                        if (Station.is_stream_url (u)) return u;
                        i = body.down ().index_of (attr, end);
                    }
                }
                return null;
            }
            foreach (string raw in body.split ("\n")) {
                string line = raw.strip ();
                if (line == "" || line.has_prefix ("#") || line.has_prefix ("[")) continue;
                int eq = line.index_of ("=");
                if (eq > 0 && line.substring (0, eq).strip ().down ().has_prefix ("file")) {
                    string v = line.substring (eq + 1).strip ();
                    if (Station.is_stream_url (v)) return v;
                    continue;
                }
                if (Station.is_stream_url (line)) return line;
            }
            return null;
        }

        public bool is_playlist_url (string url) {
            string path = url.down ();
            int q = path.index_of_char ('?');
            if (q >= 0) path = path.substring (0, q);
            return path.has_suffix (".pls") || path.has_suffix (".m3u") || path.has_suffix (".asx") || path.has_suffix (".xspf");
        }
    }

    namespace Icy {
        public string? clean_title (string? raw, string station_name = "") {
            if (raw == null) return null;
            string t = raw;
            if (t.has_prefix ("StreamTitle=")) {
                t = t.substring ("StreamTitle=".length);
                int end = t.index_of ("';");
                if (t.has_prefix ("'")) t = end > 0 ? t.substring (1, end - 1) : t.substring (1);
                if (t.has_suffix ("'")) t = t.substring (0, t.length - 1);
            }
            if (!t.validate ()) t = t.make_valid ();
            t = Station.clean_text (t);
            while (t.has_prefix ("-") || t.has_prefix ("|")) t = t.substring (1).strip ();
            while (t.has_suffix ("-") || t.has_suffix ("|")) t = t.substring (0, t.length - 1).strip ();
            if (t == "") return null;
            string low = t.down ();
            string[] junk = { "unknown", "unknown - unknown", "n/a", "null", "untitled", "-", "live", "stream" };
            foreach (string j in junk) if (low == j) return null;
            if (station_name != "" && low == station_name.strip ().down ()) return null;
            return t;
        }

        public void split (string title, out string artist, out string track) {
            artist = "";
            track = title;
            int i = title.index_of (" - ");
            if (i > 0 && i + 3 < title.length) {
                artist = title.substring (0, i).strip ();
                track = title.substring (i + 3).strip ();
            }
        }
    }
}
