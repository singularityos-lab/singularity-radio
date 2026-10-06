namespace Singularity.Apps.Radio {

    public class HistoryEntry : Object {
        public string title = "";
        public string station = "";
        public string station_key = "";
        public int64 time;

        public Json.Object to_json () {
            var o = new Json.Object ();
            o.set_string_member ("title", title);
            o.set_string_member ("station", station);
            o.set_string_member ("station_key", station_key);
            o.set_int_member ("time", time);
            return o;
        }

        public static HistoryEntry? from_json (Json.Object o) {
            var e = new HistoryEntry ();
            e.title = Station.clean_text (Station.str (o, "title"));
            e.station = Station.clean_text (Station.str (o, "station"));
            e.station_key = Station.str (o, "station_key").strip ();
            if (o.has_member ("time") && o.get_member ("time").get_node_type () == Json.NodeType.VALUE && o.get_member ("time").get_value_type () == typeof (int64)) e.time = o.get_int_member ("time");
            if (e.title == "" || e.time <= 0) return null;
            return e;
        }

        public bool same_as (string other_title, string other_key) {
            return station_key == other_key && title.casefold () == Station.clean_text (other_title).casefold ();
        }
    }

    public class History : Object {
        public const int LIMIT = 500;

        public Gee.ArrayList<HistoryEntry> entries = new Gee.ArrayList<HistoryEntry> ();
        public string error = "";
        private string path;

        public signal void changed ();

        public History (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_data_dir (), "singularity", "radio", "history.json");
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                string data;
                FileUtils.get_contents (path, out data);
                entries.add_all (parse (data));
            } catch (Error e) {
                error = e.message;
            }
        }

        public static Gee.List<HistoryEntry> parse (string data) throws Error {
            var list = new Gee.ArrayList<HistoryEntry> ();
            var parser = new Json.Parser ();
            parser.load_from_data (data, -1);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return list;
            var o = root.get_object ();
            if (!o.has_member ("entries") || o.get_member ("entries").get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in o.get_array_member ("entries").get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var e = HistoryEntry.from_json (n.get_object ());
                if (e == null) continue;
                if (list.size > 0 && list[list.size - 1].same_as (e.title, e.station_key)) continue;
                list.add (e);
                if (list.size >= LIMIT) break;
            }
            return list;
        }

        public bool record (string title, string station, string station_key, int64 time = 0) {
            string clean = Station.clean_text (title);
            if (clean == "") return false;
            if (entries.size > 0 && entries[0].same_as (clean, station_key)) return false;
            var e = new HistoryEntry ();
            e.title = clean;
            e.station = Station.clean_text (station);
            e.station_key = station_key;
            e.time = time > 0 ? time : new DateTime.now_utc ().to_unix ();
            entries.insert (0, e);
            while (entries.size > LIMIT) entries.remove_at (entries.size - 1);
            save ();
            return true;
        }

        public void remove (HistoryEntry e) {
            if (!entries.remove (e)) return;
            save ();
        }

        public void clear () {
            entries.clear ();
            save ();
        }

        public bool save () {
            var arr = new Json.Array ();
            foreach (var e in entries) arr.add_object_element (e.to_json ());
            var o = new Json.Object ();
            o.set_int_member ("version", 1);
            o.set_array_member ("entries", arr);
            var root = new Json.Node (Json.NodeType.OBJECT);
            root.set_object (o);
            var gen = new Json.Generator ();
            gen.root = root;
            bool ok = true;
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                FileUtils.set_contents (path, gen.to_data (null));
                error = "";
            } catch (Error e) {
                error = e.message;
                ok = false;
            }
            changed ();
            return ok;
        }

        public static string search_url (string engine, string title) {
            string q = Uri.escape_string (title.strip (), null, false);
            switch (engine) {
                case "google": return "https://www.google.com/search?q=" + q;
                case "bing": return "https://www.bing.com/search?q=" + q;
                case "startpage": return "https://www.startpage.com/do/search?q=" + q;
                case "ecosia": return "https://www.ecosia.org/search?q=" + q;
                default: return "https://duckduckgo.com/?q=" + q;
            }
        }
    }
}
