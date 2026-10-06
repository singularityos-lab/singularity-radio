namespace Singularity.Apps.Radio {

    public class RadioAlarm : Object {
        public const uint MONDAY = 1 << 0;
        public const uint WEEKDAYS = 0x1f;
        public const uint EVERY_DAY = 0x7f;
        public const uint WEEKENDS = EVERY_DAY & ~WEEKDAYS;

        public string id = "";
        public int hour = 7;
        public int minute;
        public uint days;
        public string label = "";
        public bool enabled = true;
        public string station_key = "";

        public string time_text () {
            return "%02d:%02d".printf (hour, minute);
        }

        public string days_text () {
            return describe_days (days);
        }

        public static string describe_days (uint days) {
            days &= EVERY_DAY;
            if (days == 0) return _("Once");
            if (days == EVERY_DAY) return _("Every day");
            if (days == WEEKDAYS) return _("Weekdays");
            if (days == WEEKENDS) return _("Weekends");
            string[] names = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") };
            string[] picked = {};
            for (int i = 0; i < 7; i++) if ((days & (MONDAY << i)) != 0) picked += names[i];
            return string.joinv (", ", picked);
        }

        public static DateTime next_ring (int hour, int minute, uint days, DateTime after) {
            var start = new DateTime.local (after.get_year (), after.get_month (), after.get_day_of_month (), 0, 0, 0);
            for (int i = 0; i < 8; i++) {
                var d = start.add_days (i);
                var at = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), hour, minute, 0);
                if (at.compare (after) <= 0) continue;
                if ((days & EVERY_DAY) == 0 || (days & (MONDAY << (at.get_day_of_week () - 1))) != 0) return at;
            }
            return start.add_days (8);
        }
    }

    namespace AlarmBridge {
        public const string APP_ID = "dev.sinty.radio";
        public const string ACTION = "play-station";
        public const string ALARMS_TYPE = "a(siiusb)";
        public const string ACTIONS_TYPE = "a{s(sss)}";

        public Gee.List<RadioAlarm> read (Variant alarms, Variant actions) {
            var list = new Gee.ArrayList<RadioAlarm> ();
            if (!alarms.is_of_type (new VariantType (ALARMS_TYPE)) || !actions.is_of_type (new VariantType (ACTIONS_TYPE))) return list;
            var iter = alarms.iterator ();
            string id, label;
            int hour, minute;
            uint days;
            bool enabled;
            while (iter.next ("(siiusb)", out id, out hour, out minute, out days, out label, out enabled)) {
                string app, action, target;
                if (!actions.lookup (id, "(sss)", out app, out action, out target)) continue;
                if (app != APP_ID || action != ACTION || target == "") continue;
                var a = new RadioAlarm ();
                a.id = id;
                a.hour = hour.clamp (0, 23);
                a.minute = minute.clamp (0, 59);
                a.days = days & RadioAlarm.EVERY_DAY;
                a.label = label;
                a.enabled = enabled;
                a.station_key = target;
                list.add (a);
            }
            list.sort ((x, y) => (x.hour * 60 + x.minute) - (y.hour * 60 + y.minute));
            return list;
        }

        public Variant put_alarm (Variant alarms, RadioAlarm a) {
            var b = new VariantBuilder (new VariantType (ALARMS_TYPE));
            bool found = false;
            var iter = alarms.iterator ();
            string id, label;
            int hour, minute;
            uint days;
            bool enabled;
            while (iter.next ("(siiusb)", out id, out hour, out minute, out days, out label, out enabled)) {
                if (id == a.id) {
                    b.add ("(siiusb)", a.id, a.hour, a.minute, a.days, a.label, a.enabled);
                    found = true;
                } else {
                    b.add ("(siiusb)", id, hour, minute, days, label, enabled);
                }
            }
            if (!found) b.add ("(siiusb)", a.id, a.hour, a.minute, a.days, a.label, a.enabled);
            return b.end ();
        }

        public Variant drop_alarm (Variant alarms, string drop_id) {
            var b = new VariantBuilder (new VariantType (ALARMS_TYPE));
            var iter = alarms.iterator ();
            string id, label;
            int hour, minute;
            uint days;
            bool enabled;
            while (iter.next ("(siiusb)", out id, out hour, out minute, out days, out label, out enabled)) {
                if (id != drop_id) b.add ("(siiusb)", id, hour, minute, days, label, enabled);
            }
            return b.end ();
        }

        public Variant link (Variant actions, Variant alarms, string alarm_id, string? station_key) {
            var ids = new Gee.HashSet<string> ();
            var iter = alarms.iterator ();
            string id, label;
            int hour, minute;
            uint days;
            bool enabled;
            while (iter.next ("(siiusb)", out id, out hour, out minute, out days, out label, out enabled)) ids.add (id);
            var b = new VariantBuilder (new VariantType (ACTIONS_TYPE));
            var entries = actions.iterator ();
            string key;
            Variant val;
            while (entries.next ("{s@(sss)}", out key, out val)) {
                if (key == alarm_id || !ids.contains (key)) continue;
                b.add ("{s@(sss)}", key, val);
            }
            if (station_key != null && station_key != "" && ids.contains (alarm_id)) {
                b.add ("{s(sss)}", alarm_id, APP_ID, ACTION, station_key);
            }
            return b.end ();
        }

        public string label_for (string station_name) {
            return _("Radio: %s").printf (station_name);
        }
    }
}
