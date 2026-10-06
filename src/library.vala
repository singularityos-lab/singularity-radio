namespace Singularity.Apps.Radio {

    public class Library : Object {
        public const int RECENT_LIMIT = 30;

        public Gee.ArrayList<Station> favorites = new Gee.ArrayList<Station> ();
        public Gee.ArrayList<Station> recent = new Gee.ArrayList<Station> ();
        public string error = "";
        private string path;

        public signal void changed ();

        public Library (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_data_dir (), "singularity", "radio", "library.json");
            load ();
        }

        private void load () {
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
                var o = root.get_object ();
                read_list (o, "favorites", favorites);
                read_list (o, "recent", recent);
            } catch (Error e) {
                error = e.message;
            }
        }

        private static void read_list (Json.Object o, string member, Gee.ArrayList<Station> into) {
            if (!o.has_member (member) || o.get_member (member).get_node_type () != Json.NodeType.ARRAY) return;
            var seen = new Gee.HashSet<string> ();
            foreach (var n in o.get_array_member (member).get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var s = Station.from_json (n.get_object ());
                if (s == null || seen.contains (s.key ())) continue;
                seen.add (s.key ());
                into.add (s);
            }
        }

        private static Json.Node write_list (Gee.List<Station> list) {
            var arr = new Json.Array ();
            foreach (var s in list) arr.add_object_element (s.to_json ());
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (arr);
            return node;
        }

        public bool save () {
            var o = new Json.Object ();
            o.set_int_member ("version", 1);
            o.set_member ("favorites", write_list (favorites));
            o.set_member ("recent", write_list (recent));
            var root = new Json.Node (Json.NodeType.OBJECT);
            root.set_object (o);
            var gen = new Json.Generator ();
            gen.root = root;
            gen.pretty = true;
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            bool ok = true;
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

        private static int index_in (Gee.List<Station> list, string key) {
            for (int i = 0; i < list.size; i++) if (list[i].key () == key) return i;
            return -1;
        }

        public bool is_favorite (Station s) {
            return index_in (favorites, s.key ()) >= 0;
        }

        public Station? find (string key) {
            int i = index_in (favorites, key);
            if (i >= 0) return favorites[i];
            i = index_in (recent, key);
            return i >= 0 ? recent[i] : null;
        }

        public void add_favorite (Station s) {
            int i = index_in (favorites, s.key ());
            if (i >= 0) favorites[i] = s;
            else favorites.add (s);
            save ();
        }

        public void remove_favorite (Station s) {
            int i = index_in (favorites, s.key ());
            if (i < 0) return;
            favorites.remove_at (i);
            save ();
        }

        public void toggle_favorite (Station s) {
            if (is_favorite (s)) remove_favorite (s);
            else add_favorite (s);
        }

        public void move_favorite (Station s, int to) {
            int i = index_in (favorites, s.key ());
            if (i < 0) return;
            var item = favorites.remove_at (i);
            favorites.insert (to.clamp (0, favorites.size), item);
            save ();
        }

        public void played (Station s) {
            int i = index_in (recent, s.key ());
            if (i >= 0) recent.remove_at (i);
            recent.insert (0, s);
            while (recent.size > RECENT_LIMIT) recent.remove_at (recent.size - 1);
            int f = index_in (favorites, s.key ());
            if (f >= 0 && !s.custom) favorites[f] = s;
            save ();
        }

        public void clear_recent () {
            recent.clear ();
            save ();
        }

        public void update_station (Station s) {
            int i = index_in (favorites, s.key ());
            if (i >= 0) favorites[i] = s;
            i = index_in (recent, s.key ());
            if (i >= 0) recent[i] = s;
            save ();
        }
    }
}
