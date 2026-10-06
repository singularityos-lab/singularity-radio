namespace Singularity.Apps.Radio {

    [DBus (name = "org.mpris.MediaPlayer2")]
    public class MprisRoot : Object {
        public signal void raise_requested ();
        public signal void quit_requested ();

        public bool can_quit { get { return true; } }
        public bool can_raise { get { return true; } }
        public bool has_track_list { get { return false; } }
        public string identity { owned get { return _("Radio"); } }
        public string desktop_entry { owned get { return "dev.sinty.radio"; } }
        public string[] supported_uri_schemes { owned get { return { "http", "https" }; } }
        public string[] supported_mime_types { owned get { return { "audio/mpeg", "audio/aac", "audio/ogg", "application/ogg", "audio/x-scpls", "audio/x-mpegurl" }; } }

        public void raise () throws DBusError, IOError {
            raise_requested ();
        }

        public void quit () throws DBusError, IOError {
            quit_requested ();
        }
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public class MprisPlayer : Object {
        private Player player;
        private Variant meta;
        private DBusConnection? conn;
        private string art_url = "";
        private string last_sent = "";

        [DBus (visible = false)]
        public signal void next_requested ();
        [DBus (visible = false)]
        public signal void previous_requested ();
        [DBus (visible = false)]
        public signal void play_requested ();
        [DBus (visible = false)]
        public signal void pause_requested ();
        [DBus (visible = false)]
        public signal void stop_requested ();
        [DBus (visible = false)]
        public signal void open_requested (string uri);

        public signal void seeked (int64 position);

        [DBus (visible = false)]
        public bool can_switch { get; set; }

        public MprisPlayer (Player player) {
            this.player = player;
            meta = build_meta ();
        }

        [DBus (visible = false)]
        public void attach (DBusConnection c) {
            conn = c;
        }

        public string playback_status {
            owned get {
                switch (player.state) {
                    case PlayState.PLAYING:
                    case PlayState.BUFFERING:
                    case PlayState.CONNECTING: return "Playing";
                    case PlayState.PAUSED: return "Paused";
                    default: return "Stopped";
                }
            }
        }

        public string loop_status { owned get { return "None"; } set {} }
        public double rate { get { return 1.0; } set {} }
        public bool shuffle { get { return false; } set {} }
        public double volume {
            get { return player.volume; }
            set { player.volume = value; }
        }
        public int64 position { get { return 0; } }
        public double minimum_rate { get { return 1.0; } }
        public double maximum_rate { get { return 1.0; } }
        public bool can_go_next { get { return can_switch; } }
        public bool can_go_previous { get { return can_switch; } }
        public bool can_play { get { return player.station != null; } }
        public bool can_pause { get { return player.station != null; } }
        public bool can_seek { get { return false; } }
        public bool can_control { get { return true; } }

        [DBus (signature = "a{sv}")]
        public Variant metadata { owned get { return meta; } }

        public void next () throws DBusError, IOError {
            next_requested ();
        }

        public void previous () throws DBusError, IOError {
            previous_requested ();
        }

        public void pause () throws DBusError, IOError {
            pause_requested ();
        }

        public void play_pause () throws DBusError, IOError {
            if (player.is_active ()) pause_requested ();
            else play_requested ();
        }

        public void stop () throws DBusError, IOError {
            stop_requested ();
        }

        public void play () throws DBusError, IOError {
            play_requested ();
        }

        public void seek (int64 offset) throws DBusError, IOError {
        }

        public void set_position (ObjectPath track_id, int64 position) throws DBusError, IOError {
        }

        public void open_uri (string uri) throws DBusError, IOError {
            open_requested (uri);
        }

        [DBus (visible = false)]
        public void set_art (string url) {
            art_url = url;
        }

        private Variant build_meta () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            var s = player.station;
            if (s == null) {
                b.add ("{sv}", "mpris:trackid", new Variant.object_path ("/org/mpris/MediaPlayer2/TrackList/NoTrack"));
                return b.end ();
            }
            b.add ("{sv}", "mpris:trackid", new Variant.object_path ("/dev/sinty/radio/station/%u".printf (s.key ().hash ())));
            string artist, track;
            if (player.now_playing != "") {
                Icy.split (player.now_playing, out artist, out track);
                b.add ("{sv}", "xesam:title", new Variant.string (track));
                b.add ("{sv}", "xesam:artist", new Variant.strv ({ artist != "" ? artist : s.name }));
            } else {
                b.add ("{sv}", "xesam:title", new Variant.string (s.name));
                string loc = s.location ();
                if (loc != "") b.add ("{sv}", "xesam:artist", new Variant.strv ({ loc }));
            }
            b.add ("{sv}", "xesam:album", new Variant.string (s.name));
            b.add ("{sv}", "xesam:url", new Variant.string (s.stream_url ()));
            if (art_url != "") b.add ("{sv}", "mpris:artUrl", new Variant.string (art_url));
            return b.end ();
        }

        [DBus (visible = false)]
        public void refresh () {
            var next = build_meta ();
            string sig = "%s|%s|%s|%s".printf (next.print (false), playback_status, can_play.to_string (), can_go_next.to_string ());
            if (sig == last_sent) return;
            last_sent = sig;
            meta = next;
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "Metadata", meta);
            b.add ("{sv}", "PlaybackStatus", new Variant.string (playback_status));
            b.add ("{sv}", "CanPlay", new Variant.boolean (can_play));
            b.add ("{sv}", "CanPause", new Variant.boolean (can_pause));
            b.add ("{sv}", "CanGoNext", new Variant.boolean (can_go_next));
            b.add ("{sv}", "CanGoPrevious", new Variant.boolean (can_go_previous));
            emit (b.end ());
        }

        [DBus (visible = false)]
        public void volume_changed () {
            var b = new VariantBuilder (new VariantType ("a{sv}"));
            b.add ("{sv}", "Volume", new Variant.double (player.volume));
            emit (b.end ());
        }

        private void emit (Variant changed) {
            if (conn == null) return;
            try {
                conn.emit_signal (null, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    new Variant.tuple ({ new Variant.string ("org.mpris.MediaPlayer2.Player"), changed, new Variant.array (VariantType.STRING, {}) }));
            } catch (Error e) {
                warning ("radio: MPRIS signal failed: %s", e.message);
            }
        }
    }

    public class Mpris : Object {
        public MprisRoot root = new MprisRoot ();
        public MprisPlayer player;
        private uint owner;
        private uint[] objects = {};
        private DBusConnection? conn;

        public Mpris (Player p) {
            player = new MprisPlayer (p);
        }

        public void start () {
            owner = Bus.own_name (BusType.SESSION, "org.mpris.MediaPlayer2.singularity-radio", BusNameOwnerFlags.NONE,
                (c) => {
                    conn = c;
                    player.attach (c);
                    try {
                        objects += c.register_object ("/org/mpris/MediaPlayer2", root);
                        objects += c.register_object ("/org/mpris/MediaPlayer2", player);
                    } catch (IOError e) {
                        warning ("radio: MPRIS could not be registered: %s", e.message);
                    }
                },
                null,
                () => { });
        }

        public void stop () {
            if (conn != null) foreach (uint id in objects) conn.unregister_object (id);
            objects = {};
            if (owner != 0) Bus.unown_name (owner);
            owner = 0;
        }
    }
}
