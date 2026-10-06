using Gtk;

namespace Singularity.Apps.Radio {

    public class RadioApp : Singularity.Application {
        public Library library;
        public Directory directory;
        public Favicons favicons;
        public Player player;
        public Mpris mpris;
        public History history;
        public SleepTimer sleep;
        public AlarmService alarms;
        public GLib.Settings? settings;
        private Singularity.DockMenu? dock_menu;
        private bool background_held;
        private bool play_last_pending;
        private string sleep_label = "";

        public RadioApp () {
            Object (application_id: "dev.sinty.radio", flags: ApplicationFlags.DEFAULT_FLAGS);
            add_main_option ("play-last", 0, OptionFlags.NONE, OptionArg.NONE, _("Play the last station without opening a window"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("play-last")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("radio: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("play-last", null);
                return 0;
            }
            play_last_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            library = new Library ();
            directory = new Directory ();
            favicons = new Favicons (directory.http);
            player = new Player ();
            mpris = new Mpris (player);
            mpris.start ();
            var source = SettingsSchemaSource.get_default ();
            if (source != null && source.lookup ("dev.sinty.radio", true) != null) settings = new GLib.Settings ("dev.sinty.radio");
            history = new History ();
            sleep = new SleepTimer ();
            alarms = new AlarmService ();
            sleep.notify["level"].connect (() => player.fade = sleep.level);
            sleep.expired.connect (() => {
                player.pause ();
                player.fade = 1.0;
            });
            player.notify["state"].connect (() => {
                if (player.state == PlayState.STOPPED) sleep.cancel ();
                if (player.state == PlayState.PLAYING) on_metadata ();
                if (!player.is_active () && player.state != PlayState.BUFFERING) drop_background ();
            });
            sleep.changed.connect (sync_sleep_dock);
            player.metadata_changed.connect (sync_mpris);
            player.notify["state"].connect (sync_mpris);
            mpris.player.play_requested.connect (() => resume ());
            mpris.player.pause_requested.connect (() => player.pause ());
            mpris.player.stop_requested.connect (() => player.stop ());
            mpris.player.next_requested.connect (() => step_station (1));
            mpris.player.previous_requested.connect (() => step_station (-1));
            dock_menu = new Singularity.DockMenu ("dev.sinty.radio");
            dock_menu.activated.connect (on_dock_menu);
            library.changed.connect (publish_dock_menu);
            publish_dock_menu ();
            player.metadata_changed.connect (on_metadata);
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);

            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Add Custom Station…"), "win.add-custom");
            f1.append (_("New Radio Alarm…"), "win.new-alarm");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file.append_section (null, f2);
            menu.append_submenu (_("File"), file);

            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Find"), "win.find");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Add to Library"), "win.toggle-library");
            e2.append (_("Copy Stream Address"), "win.copy-stream");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Copy Song Title"), "win.copy-title");
            e3.append (_("Search the Web for Song"), "win.search-title");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Clear Recently Played"), "win.clear-recent");
            e4.append (_("Clear History"), "win.clear-history");
            edit.append_section (null, e4);
            var e5 = new GLib.Menu ();
            e5.append (_("Settings"), "app.settings");
            edit.append_section (null, e5);
            menu.append_submenu (_("Edit"), edit);

            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Library"), "win.show-library");
            v1.append (_("Recently Played"), "win.show-recent");
            v1.append (_("History"), "win.show-history");
            v1.append (_("Alarms"), "win.show-alarms");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Popular"), "win.show-popular");
            v2.append (_("Near You"), "win.show-local");
            v2.append (_("Genres"), "win.show-genres");
            v2.append (_("Countries"), "win.show-countries");
            v2.append (_("Languages"), "win.show-languages");
            view.append_section (null, v2);
            var v3 = new GLib.Menu ();
            v3.append (_("Back"), "win.back");
            v3.append (_("Reload"), "win.reload");
            view.append_section (null, v3);
            var v4 = new GLib.Menu ();
            v4.append (_("Show Sidebar"), "win.toggle-sidebar");
            view.append_section (null, v4);
            menu.append_submenu (_("View"), view);

            var playback = new GLib.Menu ();
            var p1 = new GLib.Menu ();
            p1.append (_("Play or Pause"), "win.play-pause");
            p1.append (_("Stop"), "win.stop");
            playback.append_section (null, p1);
            var p2 = new GLib.Menu ();
            p2.append (_("Previous Station"), "win.previous");
            p2.append (_("Next Station"), "win.next");
            playback.append_section (null, p2);
            var p3 = new GLib.Menu ();
            p3.append (_("Volume Up"), "win.volume-up");
            p3.append (_("Volume Down"), "win.volume-down");
            p3.append (_("Mute"), "win.mute");
            playback.append_section (null, p3);
            var p4 = new GLib.Menu ();
            p4.append (_("Sleep Timer…"), "win.sleep-timer");
            p4.append (_("Cancel Sleep Timer"), "win.cancel-sleep");
            playback.append_section (null, p4);
            menu.append_submenu (_("Playback"), playback);

            var help = new GLib.Menu ();
            help.append (_("About Radio"), "app.about");
            menu.append_submenu (_("Help"), help);
            set_menubar (menu);

            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => quit_all ());
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.radio");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var play_station = new SimpleAction ("play-station", VariantType.STRING);
            play_station.activate.connect ((param) => {
                activate ();
                var w = get_active_window () as RadioWindow;
                if (w != null) w.play_key (param.get_string ());
            });
            add_action (play_station);
            var play_favorite = new SimpleAction ("play-favorite", VariantType.STRING);
            play_favorite.activate.connect ((param) => {
                var st = library.find (param.get_string ());
                if (st != null) play_in_background (st);
            });
            add_action (play_favorite);
            var play_last = new SimpleAction ("play-last", null);
            play_last.activate.connect (() => {
                if (library.recent.size > 0) play_in_background (library.recent[0]);
                else if (library.favorites.size > 0) play_in_background (library.favorites[0]);
                else activate ();
            });
            add_action (play_last);
            about_name = _("Radio");
            about_version = "0.1.0";
            about_description = _("Listen to internet radio stations from around the world.");
            about_website = "https://github.com/singularityos-lab/singularity-desktop";
            about_license = _("GNU General Public License, version 3 only");
            about_credits = _("Station directory by radio-browser.info");
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.new-alarm", { "<Control><Shift>n" });
            set_accels_for_action ("win.copy-title", { "<Control><Shift>c" });
            set_accels_for_action ("win.search-title", { "<Control><Shift>f" });
            set_accels_for_action ("win.show-history", { "<Control>5" });
            set_accels_for_action ("win.show-alarms", { "<Control>6" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.toggle-sidebar", { "F9" });
            set_accels_for_action ("win.sleep-timer", { "<Control>t" });
            set_accels_for_action ("win.cancel-sleep", { "<Control><Shift>t" });
            set_accels_for_action ("win.add-custom", { "<Control>n" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.toggle-library", { "<Control>d" });
            set_accels_for_action ("win.show-library", { "<Control>1" });
            set_accels_for_action ("win.show-recent", { "<Control>2" });
            set_accels_for_action ("win.show-popular", { "<Control>3" });
            set_accels_for_action ("win.show-local", { "<Control>4" });
            set_accels_for_action ("win.back", { "<Alt>Left" });
            set_accels_for_action ("win.reload", { "<Control>r", "F5" });
            set_accels_for_action ("win.play-pause", { "<Control>space" });
            set_accels_for_action ("win.stop", { "<Control>period" });
            set_accels_for_action ("win.previous", { "<Control>Page_Up" });
            set_accels_for_action ("win.next", { "<Control>Page_Down" });
            set_accels_for_action ("win.volume-up", { "<Control>Up" });
            set_accels_for_action ("win.volume-down", { "<Control>Down" });
            set_accels_for_action ("win.mute", { "<Control>m" });

            mpris.root.quit_requested.connect (() => quit_all ());
            mpris.root.raise_requested.connect (() => activate ());
        }

        public bool record_enabled () {
            return settings == null || settings.get_boolean ("record-history");
        }

        public string search_engine () {
            return settings != null ? settings.get_string ("web-search") : "duckduckgo";
        }

        public void play_station (Station s) {
            library.played (s);
            if (!Directory.online ()) {
                player.connecting (s);
                player.fail (_("You are offline. Connect to the internet to listen."));
                return;
            }
            directory.count_click (s);
            string url = s.stream_url ();
            if (!Parse.is_playlist_url (url)) {
                player.play (s, url);
                return;
            }
            player.connecting (s);
            directory.resolve_stream.begin (url, null, (o, res) => {
                try {
                    string resolved = directory.resolve_stream.end (res);
                    if (player.station == null || player.station.key () != s.key () || player.state != PlayState.CONNECTING) return;
                    player.play (s, resolved);
                } catch (Error e) {
                    if (player.station != null && player.station.key () == s.key ()) player.fail (e.message);
                }
            });
        }

        public void resume () {
            if (player.station == null) {
                if (library.favorites.size > 0) play_station (library.favorites[0]);
                else if (library.recent.size > 0) play_station (library.recent[0]);
                return;
            }
            if (!player.is_active ()) play_station (player.station);
        }

        public void step_station (int dir) {
            var list = library.favorites.size > 1 ? library.favorites : library.recent;
            if (list.size == 0) return;
            int idx = -1;
            if (player.station != null) {
                for (int i = 0; i < list.size; i++) if (list[i].key () == player.station.key ()) idx = i;
            }
            int next = idx < 0 ? 0 : (idx + dir + list.size) % list.size;
            play_station (list[next]);
        }

        private void play_in_background (Station s) {
            if (get_active_window () == null && get_windows ().length () == 0 && !background_held) {
                background_held = true;
                hold ();
            }
            player.muted = false;
            play_station (s);
        }

        private void quit_all () {
            foreach (var w in get_windows ()) w.close ();
            drop_background ();
        }

        private void sync_mpris () {
            var s = player.station;
            if (s != null) {
                string? file = s.favicon != "" ? favicons.cached_file (s.favicon) : null;
                mpris.player.set_art (file != null ? File.new_for_path (file).get_uri () : "");
            }
            mpris.player.can_switch = library.favorites.size > 1 || library.recent.size > 1;
            mpris.player.refresh ();
        }

        private void drop_background () {
            if (!background_held) return;
            background_held = false;
            release ();
        }

        private void publish_dock_menu () {
            if (dock_menu == null) return;
            dock_menu.clear ();
            int shown = 0;
            foreach (var s in library.favorites) {
                if (shown >= 8) break;
                dock_menu.add_item ("fav:" + s.key (), s.name, "starred-symbolic");
                shown++;
            }
            if (library.recent.size > 0) {
                var last = library.recent[0];
                if (shown > 0) dock_menu.add_separator ();
                dock_menu.add_item ("last:" + last.key (), _("Last Played: %s").printf (last.name), "document-open-recent-symbolic");
                shown++;
            }
            if (shown == 0) dock_menu.unpublish ();
            else dock_menu.publish ();
        }

        private void on_dock_menu (string id) {
            int colon = id.index_of_char (':');
            if (colon < 0) return;
            var s = library.find (id.substring (colon + 1));
            if (s != null) play_in_background (s);
        }

        private void sync_sleep_dock () {
            string text = "";
            string tip = "";
            if (sleep.active) {
                int left = sleep.remaining ();
                text = left >= 0 ? SleepTimer.format (left) : _("End of song");
                tip = left >= 0 ? _("Stops in %s").printf (SleepTimer.format (left)) : _("Stops when the song ends");
            }
            if (text == sleep_label) return;
            sleep_label = text;
            var conn = get_dbus_connection ();
            if (conn == null) return;
            if (text == "") {
                conn.call.begin ("dev.sinty.Dock", "/dev/sinty/Dock", "dev.sinty.Dock", "ClearSuffix",
                    new Variant ("(s)", "dev.sinty.radio"), null, DBusCallFlags.NO_AUTO_START, 2000, null);
                return;
            }
            var props = new VariantBuilder (VariantType.VARDICT);
            props.add ("{sv}", "id", new Variant.string ("sleep"));
            props.add ("{sv}", "label", new Variant.string (text));
            props.add ("{sv}", "tooltip", new Variant.string (tip));
            var widgets = new VariantBuilder (new VariantType ("a(sa{sv})"));
            widgets.add ("(s@a{sv})", "label", props.end ());
            conn.call.begin ("dev.sinty.Dock", "/dev/sinty/Dock", "dev.sinty.Dock", "SetSuffix",
                new Variant ("(sv)", "dev.sinty.radio", widgets.end ()), null, DBusCallFlags.NO_AUTO_START, 2000, null);
        }

        private void on_metadata () {
            string title = player.now_playing;
            sleep.song_changed (title);
            if (title == "" || player.station == null || !record_enabled ()) return;
            if (player.state != PlayState.PLAYING && player.state != PlayState.BUFFERING) return;
            history.record (title, player.station.name, player.station.key ());
        }

        protected override void shutdown () {
            player.shutdown ();
            mpris.stop ();
            base.shutdown ();
        }

        public override void activate () {
            if (play_last_pending) {
                play_last_pending = false;
                activate_action ("play-last", null);
                return;
            }
            var w = get_active_window ();
            if (w == null) w = new RadioWindow (this);
            w.present ();
            drop_background ();
        }

        private const string CSS = """
.radio-page {
    padding: 0 24px 24px 24px;
}

.radio-page-title {
    font-weight: 800;
    font-size: 22px;
}

.radio-list {
    background: transparent;
}

.radio-list > row {
    border-radius: 12px;
    padding: 6px 8px;
}

.radio-row-name {
    font-weight: 700;
}

.radio-row-playing .radio-row-name {
    color: @accent_color;
}

.radio-art {
    border-radius: 10px;
    background-color: alpha(@window_fg_color, 0.06);
}

.radio-chip {
    border-radius: 99px;
    padding: 4px 12px;
    background-color: alpha(@window_fg_color, 0.07);
}

.radio-chip:hover {
    background-color: alpha(@window_fg_color, 0.12);
}

.radio-chip-count {
    font-size: 11px;
    opacity: 0.65;
    font-feature-settings: "tnum";
}

.radio-detail-name {
    font-weight: 800;
    font-size: 26px;
}

.radio-bar {
    padding: 10px 16px;
    border-top: 1px solid alpha(@window_fg_color, 0.08);
    background-color: alpha(@window_fg_color, 0.03);
}

.radio-bar-title {
    font-weight: 700;
}

.radio-bar-status {
    font-size: 13px;
}

.radio-bar-status.error {
    color: @error_color;
}

.radio-bar-info {
    font-size: 12px;
    font-feature-settings: "tnum";
}

.radio-play {
    min-width: 42px;
    min-height: 42px;
    padding: 0;
    border-radius: 99px;
}

.radio-round {
    min-width: 34px;
    min-height: 34px;
    padding: 0;
    border-radius: 99px;
}

.radio-volume {
    min-width: 110px;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-radio", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-radio", "UTF-8");
        Intl.textdomain ("singularity-radio");
        Gst.init (ref args);
        return new RadioApp ().run (args);
    }
}
