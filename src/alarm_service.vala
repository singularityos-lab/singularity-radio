namespace Singularity.Apps.Radio {

    public class AlarmService : Object {
        public const string CLOCK_SCHEMA = "dev.sinty.clock";

        private GLib.Settings? clock;
        private Gee.HashMap<string, Station> stations = new Gee.HashMap<string, Station> ();
        private string path;
        private bool writing;

        public string error { get; private set; default = ""; }
        public bool available { get { return clock != null; } }

        public signal void changed ();

        public AlarmService () {
            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "radio", "alarm-stations.json");
            var source = SettingsSchemaSource.get_default ();
            var schema = source != null ? source.lookup (CLOCK_SCHEMA, true) : null;
            if (schema != null && schema.has_key ("alarms") && schema.has_key ("alarm-actions")) {
                clock = new GLib.Settings.full (schema, null, null);
                clock.changed.connect ((key) => {
                    if (!writing && (key == "alarms" || key == "alarm-actions")) changed ();
                });
            }
            load_stations ();
        }

        public Gee.List<RadioAlarm> alarms () {
            if (clock == null) return new Gee.ArrayList<RadioAlarm> ();
            return AlarmBridge.read (clock.get_value ("alarms"), clock.get_value ("alarm-actions"));
        }

        public Station? station (string key) {
            return stations[key];
        }

        public bool save (RadioAlarm a, Station s) {
            if (clock == null) return false;
            if (a.id == "") a.id = Uuid.string_random ();
            a.station_key = s.key ();
            a.label = AlarmBridge.label_for (s.name);
            stations[s.key ()] = s;
            var alarms = AlarmBridge.put_alarm (clock.get_value ("alarms"), a);
            var actions = AlarmBridge.link (clock.get_value ("alarm-actions"), alarms, a.id, a.station_key);
            commit (alarms, actions);
            save_stations ();
            wake_clock ();
            return true;
        }

        public void set_enabled (RadioAlarm a, bool on) {
            if (clock == null) return;
            a.enabled = on;
            var alarms = AlarmBridge.put_alarm (clock.get_value ("alarms"), a);
            commit (alarms, clock.get_value ("alarm-actions"));
            if (on) wake_clock ();
        }

        public void remove (RadioAlarm a) {
            if (clock == null) return;
            var alarms = AlarmBridge.drop_alarm (clock.get_value ("alarms"), a.id);
            var actions = AlarmBridge.link (clock.get_value ("alarm-actions"), alarms, a.id, null);
            commit (alarms, actions);
            save_stations ();
        }

        private void commit (Variant alarms, Variant actions) {
            writing = true;
            clock.delay ();
            clock.set_value ("alarm-actions", actions);
            clock.set_value ("alarms", alarms);
            clock.apply ();
            writing = false;
            changed ();
        }

        public bool wake_clock () {
            string? program = Environment.find_program_in_path ("singularity-clock");
            if (program == null) {
                error = _("Clock is not installed, so the alarm cannot ring.");
                return false;
            }
            try {
                new Subprocess.newv ({ program, "--background" }, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                error = "";
                return true;
            } catch (Error e) {
                error = e.message;
                return false;
            }
        }

        private void load_stations () {
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var n in root.get_array ().get_elements ()) {
                    if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                    var s = Station.from_json (n.get_object ());
                    if (s != null) stations[s.key ()] = s;
                }
            } catch (Error e) {
                error = e.message;
            }
        }

        private void save_stations () {
            var used = new Gee.HashSet<string> ();
            foreach (var a in alarms ()) used.add (a.station_key);
            var arr = new Json.Array ();
            foreach (var e in stations.entries) {
                if (used.contains (e.key)) arr.add_object_element (e.value.to_json ());
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.root = root;
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                FileUtils.set_contents (path, gen.to_data (null));
            } catch (Error e) {
                error = e.message;
            }
        }
    }
}
