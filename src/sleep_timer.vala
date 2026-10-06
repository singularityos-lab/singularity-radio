namespace Singularity.Apps.Radio {

    public enum SleepMode {
        OFF,
        MINUTES,
        END_OF_SONG
    }

    public class SleepTimer : Object {
        public const int FADE_SECONDS = 30;
        public const int SONG_FADE_SECONDS = 5;
        public const int[] PRESETS = { 15, 30, 45, 60 };

        public SleepMode mode { get; private set; default = SleepMode.OFF; }
        public double level { get; private set; default = 1.0; }
        public bool active { get { return mode != SleepMode.OFF; } }

        private int64 deadline;
        private int64 song_end = -1;
        private string song = "";
        private uint tick_id;
        private bool driven;

        public signal void changed ();
        public signal void expired ();

        public SleepTimer (bool driven = true) {
            this.driven = driven;
        }

        public static int64 now () {
            return get_monotonic_time ();
        }

        public void start_minutes (int minutes, int64 at = -1) {
            if (at < 0) at = now ();
            stop_ticking ();
            mode = SleepMode.MINUTES;
            deadline = at + (int64) minutes.clamp (1, 24 * 60) * 60 * TimeSpan.SECOND;
            song_end = -1;
            level = 1.0;
            start_ticking ();
            changed ();
        }

        public bool start_end_of_song (string title) {
            if (title.strip () == "") return false;
            stop_ticking ();
            mode = SleepMode.END_OF_SONG;
            song = title;
            song_end = -1;
            level = 1.0;
            start_ticking ();
            changed ();
            return true;
        }

        public void song_changed (string title, int64 at = -1) {
            if (mode != SleepMode.END_OF_SONG || song_end >= 0 || title == song) return;
            if (at < 0) at = now ();
            song_end = at;
            changed ();
        }

        public void cancel () {
            if (mode == SleepMode.OFF) return;
            stop_ticking ();
            mode = SleepMode.OFF;
            level = 1.0;
            song_end = -1;
            changed ();
        }

        public int remaining (int64 at = -1) {
            if (at < 0) at = now ();
            if (mode == SleepMode.MINUTES) return (int) ((int64.max (deadline - at, 0) + TimeSpan.SECOND - 1) / TimeSpan.SECOND);
            if (mode == SleepMode.END_OF_SONG && song_end >= 0) {
                int64 left = song_end + SONG_FADE_SECONDS * TimeSpan.SECOND - at;
                return (int) ((int64.max (left, 0) + TimeSpan.SECOND - 1) / TimeSpan.SECOND);
            }
            return -1;
        }

        public bool update (int64 at) {
            if (mode == SleepMode.OFF) return false;
            int64 left;
            int fade;
            if (mode == SleepMode.MINUTES) {
                left = deadline - at;
                fade = FADE_SECONDS;
            } else if (song_end >= 0) {
                left = song_end + SONG_FADE_SECONDS * TimeSpan.SECOND - at;
                fade = SONG_FADE_SECONDS;
            } else {
                return false;
            }
            level = fade_level (left, fade);
            if (left > 0) return false;
            stop_ticking ();
            mode = SleepMode.OFF;
            song_end = -1;
            expired ();
            if (mode == SleepMode.OFF) level = 1.0;
            changed ();
            return true;
        }

        public static double fade_level (int64 left, int fade_seconds) {
            if (left <= 0) return 0.0;
            int64 span = (int64) fade_seconds * TimeSpan.SECOND;
            if (left >= span) return 1.0;
            return (double) left / span;
        }

        public static string format (int seconds) {
            if (seconds < 0) seconds = 0;
            int h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60;
            if (h > 0) return "%d:%02d:%02d".printf (h, m, s);
            return "%d:%02d".printf (m, s);
        }

        private void start_ticking () {
            if (!driven) return;
            tick_id = Timeout.add (250, () => {
                uint id = tick_id;
                tick_id = 0;
                if (update (now ()) || mode == SleepMode.OFF) return Source.REMOVE;
                tick_id = id;
                changed ();
                return Source.CONTINUE;
            });
        }

        private void stop_ticking () {
            if (tick_id != 0) Source.remove (tick_id);
            tick_id = 0;
        }
    }
}
