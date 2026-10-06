namespace Singularity.Apps.Radio {

    public enum PlayState {
        STOPPED,
        CONNECTING,
        BUFFERING,
        PLAYING,
        PAUSED,
        FAILED
    }

    public class Player : Object {
        private Gst.Element? playbin;
        private uint bus_watch;
        private uint stall_id;
        private uint error_id;
        private Error? pending_error;
        private bool want_playing;
        private int serial;

        public Station? station { get; private set; }
        public PlayState state { get; private set; default = PlayState.STOPPED; }
        public int buffer_percent { get; private set; default = 0; }
        public string now_playing { get; private set; default = ""; }
        public string stream_info { get; private set; default = ""; }
        public string failure { get; private set; default = ""; }
        public bool available { get { return playbin != null; } }

        private double _volume = 0.8;
        public double volume {
            get { return _volume; }
            set {
                _volume = value.clamp (0.0, 1.0);
                apply_volume ();
            }
        }

        private double _fade = 1.0;
        public double fade {
            get { return _fade; }
            set {
                _fade = value.clamp (0.0, 1.0);
                apply_volume ();
            }
        }

        private bool _muted;
        public bool muted {
            get { return _muted; }
            set {
                _muted = value;
                apply_volume ();
            }
        }

        public signal void metadata_changed ();

        public Player () {
            playbin = Gst.ElementFactory.make ("playbin", "radio");
            if (playbin == null) return;
            var fakevideo = Gst.ElementFactory.make ("fakesink", null);
            if (fakevideo != null) playbin.set_property ("video-sink", fakevideo);
            playbin.set_property ("buffer-duration", (int64) (3 * Gst.SECOND));
            var bus = playbin.get_bus ();
            bus_watch = bus.add_watch (Priority.DEFAULT, on_message);
            apply_volume ();
        }

        public void shutdown () {
            cancel_stall ();
            if (playbin != null) playbin.set_state (Gst.State.NULL);
            if (bus_watch != 0) Source.remove (bus_watch);
            bus_watch = 0;
        }

        private void apply_volume () {
            if (playbin == null) return;
            double linear = Gst.Audio.StreamVolume.convert_volume (Gst.Audio.StreamVolumeFormat.CUBIC, Gst.Audio.StreamVolumeFormat.LINEAR, _volume * _fade);
            playbin.set_property ("volume", linear);
            playbin.set_property ("mute", _muted);
        }

        public void play (Station s, string uri) {
            if (playbin == null) {
                station = s;
                fail (_("Audio playback is not available. The GStreamer playbin element is missing."));
                return;
            }
            serial++;
            pending_error = null;
            bool same = station != null && station.key () == s.key ();
            station = s;
            if (!same) {
                now_playing = "";
                stream_info = s.format_quality ();
            }
            failure = "";
            want_playing = true;
            buffer_percent = 0;
            playbin.set_state (Gst.State.NULL);
            playbin.set_property ("uri", uri);
            state = PlayState.CONNECTING;
            metadata_changed ();
            var ret = playbin.set_state (Gst.State.PLAYING);
            if (ret == Gst.StateChangeReturn.FAILURE) {
                fail (_("The stream could not be opened."));
                return;
            }
            watch_stall ();
        }

        public void cue (Station s) {
            if (station != null) return;
            station = s;
            stream_info = s.format_quality ();
            state = PlayState.PAUSED;
            metadata_changed ();
        }

        public void connecting (Station s) {
            serial++;
            if (playbin != null) playbin.set_state (Gst.State.NULL);
            bool same = station != null && station.key () == s.key ();
            station = s;
            if (!same) {
                now_playing = "";
                stream_info = s.format_quality ();
            }
            failure = "";
            want_playing = true;
            state = PlayState.CONNECTING;
            metadata_changed ();
        }

        public void pause () {
            if (station == null) return;
            want_playing = false;
            cancel_stall ();
            if (playbin != null) playbin.set_state (Gst.State.NULL);
            state = PlayState.PAUSED;
            buffer_percent = 0;
        }

        public void stop () {
            want_playing = false;
            cancel_stall ();
            serial++;
            if (playbin != null) playbin.set_state (Gst.State.NULL);
            station = null;
            now_playing = "";
            stream_info = "";
            failure = "";
            buffer_percent = 0;
            state = PlayState.STOPPED;
            metadata_changed ();
        }

        public void fail (string message) {
            want_playing = false;
            cancel_stall ();
            if (playbin != null) playbin.set_state (Gst.State.NULL);
            failure = message;
            state = PlayState.FAILED;
            metadata_changed ();
        }

        public bool is_active () {
            return state == PlayState.PLAYING || state == PlayState.BUFFERING || state == PlayState.CONNECTING;
        }

        private void watch_stall () {
            cancel_stall ();
            int mine = serial;
            int last_percent = -1;
            int idle_ticks = 0;
            stall_id = Timeout.add_seconds (1, () => {
                if (mine != serial || !want_playing) {
                    stall_id = 0;
                    return Source.REMOVE;
                }
                if (state == PlayState.PLAYING) {
                    idle_ticks = 0;
                    last_percent = buffer_percent;
                    return Source.CONTINUE;
                }
                if (buffer_percent != last_percent) {
                    last_percent = buffer_percent;
                    idle_ticks = 0;
                } else {
                    idle_ticks++;
                }
                if (idle_ticks >= 20) {
                    stall_id = 0;
                    fail (_("The station is not answering. It may be offline or overloaded."));
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        private void cancel_stall () {
            if (stall_id != 0) Source.remove (stall_id);
            stall_id = 0;
        }

        public static string describe_error (Error err) {
            if (err is Gst.ResourceError) {
                int c = err.code;
                if (c == Gst.ResourceError.NOT_FOUND) return _("The stream address was not found. The station may have moved.");
                if (c == Gst.ResourceError.OPEN_READ || c == Gst.ResourceError.READ) return _("The stream could not be read. The station may be offline.");
                if (c == Gst.ResourceError.NOT_AUTHORIZED) return _("The station refused the connection.");
                if (c == Gst.ResourceError.BUSY) return _("The station is busy. Try again later.");
            }
            if (err is Gst.StreamError) {
                int c = err.code;
                if (c == Gst.StreamError.TYPE_NOT_FOUND) return _("The station sent no playable audio. It may be offline, or its format is not supported.");
                if (c == Gst.StreamError.CODEC_NOT_FOUND || c == Gst.StreamError.WRONG_TYPE) return _("The stream format is not supported. A GStreamer plugin may be missing.");
                if (c == Gst.StreamError.DECODE || c == Gst.StreamError.DEMUX) return _("The stream is damaged and cannot be played.");
            }
            if (err is Gst.CoreError && err.code == Gst.CoreError.MISSING_PLUGIN) return _("The stream format is not supported. A GStreamer plugin may be missing.");
            return err.message;
        }

        private static int error_rank (Error err) {
            if (err is Gst.ResourceError) return 3;
            if (err is Gst.CoreError && err.code == Gst.CoreError.MISSING_PLUGIN) return 3;
            if (err is Gst.StreamError && err.code != Gst.StreamError.FAILED) return 2;
            return 1;
        }

        private void report_error (Error err) {
            if (pending_error == null || error_rank (err) > error_rank (pending_error)) pending_error = err.copy ();
            if (error_id != 0) return;
            int mine = serial;
            error_id = Timeout.add (250, () => {
                error_id = 0;
                var e = pending_error;
                pending_error = null;
                if (mine == serial && want_playing && e != null) fail (describe_error (e));
                return Source.REMOVE;
            });
        }

        private bool on_message (Gst.Bus bus, Gst.Message msg) {
            switch (msg.type) {
                case Gst.MessageType.ERROR:
                    Error err;
                    string debug;
                    msg.parse_error (out err, out debug);
                    if (want_playing) report_error (err);
                    break;
                case Gst.MessageType.EOS:
                    if (want_playing) fail (_("The station stopped broadcasting."));
                    break;
                case Gst.MessageType.BUFFERING:
                    int percent;
                    msg.parse_buffering (out percent);
                    buffer_percent = percent;
                    if (!want_playing) break;
                    if (percent < 100) {
                        if (state == PlayState.PLAYING) playbin.set_state (Gst.State.PAUSED);
                        if (state != PlayState.CONNECTING || percent > 0) state = PlayState.BUFFERING;
                    } else {
                        playbin.set_state (Gst.State.PLAYING);
                    }
                    break;
                case Gst.MessageType.STATE_CHANGED:
                    if (msg.src != playbin) break;
                    Gst.State old_state, new_state, pending;
                    msg.parse_state_changed (out old_state, out new_state, out pending);
                    if (new_state == Gst.State.PLAYING && want_playing) {
                        buffer_percent = 100;
                        state = PlayState.PLAYING;
                    }
                    break;
                case Gst.MessageType.TAG:
                    Gst.TagList tags;
                    msg.parse_tag (out tags);
                    read_tags (tags);
                    break;
                default:
                    break;
            }
            return Source.CONTINUE;
        }

        private void read_tags (Gst.TagList tags) {
            bool changed = false;
            string? title = null;
            if (tags.get_string (Gst.Tags.TITLE, out title)) {
                string? artist = null;
                tags.get_string (Gst.Tags.ARTIST, out artist);
                string? full = title;
                if (artist != null && artist.strip () != "" && title != null && !title.contains (artist)) full = "%s - %s".printf (artist.strip (), title.strip ());
                string clean = Icy.clean_title (full, station != null ? station.name : "") ?? "";
                if (clean != now_playing) {
                    now_playing = clean;
                    changed = true;
                }
            }
            string? codec = null;
            uint rate = 0;
            string[] info = {};
            if (tags.get_string (Gst.Tags.AUDIO_CODEC, out codec) && codec != null) info += Station.clean_text (codec);
            if (tags.get_uint (Gst.Tags.NOMINAL_BITRATE, out rate) && rate > 1000) info += "%u kbps".printf (rate / 1000);
            else if (tags.get_uint (Gst.Tags.BITRATE, out rate) && rate > 1000) info += "%u kbps".printf ((rate + 500) / 1000);
            if (info.length > 0) {
                string joined = string.joinv (" ", info);
                if (joined != stream_info) {
                    stream_info = joined;
                    changed = true;
                }
            }
            if (changed) metadata_changed ();
        }
    }
}
