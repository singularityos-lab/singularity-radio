using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Radio {

    public class View : Object {
        public string kind = "";
        public string title = "";
        public string subtitle = "";
        public string nav = "";
        public Query? query;
        public Station? station;
        public Gee.ArrayList<Station>? results;
        public bool more;
        public double scroll;
    }

    private class RowRef : Object {
        public Station station;
        public ListBoxRow row;
        public Button play;
        public Button star;
    }

    public class RadioWindow : Singularity.Widgets.Window {
        private RadioApp app;
        private Library library;
        private Directory directory;
        private Favicons favicons;
        private Player player;
        private History songs;
        private SleepTimer sleep;
        private AlarmService alarms;
        private AppSidebar sidebar;
        private Stack stack;
        private ScrolledWindow scroll;
        private Box page;
        private Gee.HashMap<string, SidebarRow> nav_rows = new Gee.HashMap<string, SidebarRow> ();
        private View view;
        private Gee.ArrayList<View> history = new Gee.ArrayList<View> ();
        private Gee.ArrayList<RowRef> row_refs = new Gee.ArrayList<RowRef> ();
        private Gee.HashMap<string, Gee.List<Parse.Facet>> facet_cache = new Gee.HashMap<string, Gee.List<Parse.Facet>> ();
        private Cancellable? loading;
        private bool load_failed;
        private SearchBubble search;
        private Button back_bubble;
        private BubbleSwitcher search_switcher;
        private string search_mode = "name";
        private uint search_timer;
        private string local_code = "";

        private Revealer bar_reveal;
        private StationArt bar_art;
        private Label bar_title;
        private Label bar_status;
        private Label bar_info;
        private Button bar_play;
        private Button bar_star;
        private Button bar_mute;
        private Scale bar_volume;
        private Button bar_sleep;
        private Label bar_sleep_label;
        private bool syncing_volume;

        private KeyFile state = new KeyFile ();
        private string state_path;
        private uint save_id;
        private ulong detail_handler;

        public RadioWindow (RadioApp app) {
            Object (application: app);
            this.app = app;
            library = app.library;
            directory = app.directory;
            favicons = app.favicons;
            player = app.player;
            songs = app.history;
            sleep = app.sleep;
            alarms = app.alarms;
            set_default_size (1080, 740);
            set_title (_("Radio"));
            local_code = locale_country ();
            state_path = Path.build_filename (Environment.get_user_config_dir (), "singularity", "radio.ini");
            try {
                state.load_from_file (state_path, KeyFileFlags.NONE);
            } catch (Error e) {
            }

            sidebar = new AppSidebar (220);
            set_sidebar (sidebar);
            set_sidebar_visible (true);
            build_sidebar ();

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.vexpand = true;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_alarms_welcome (), "alarms-empty");
            page = new Box (Orientation.VERTICAL, 16);
            page.add_css_class ("radio-page");
            scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = page;
            apply_view_edge (scroll);
            stack.add_named (scroll, "page");

            var content = new Box (Orientation.VERTICAL, 0);
            content.append (stack);
            content.append (build_bar ());
            set_content (content);

            back_bubble = add_bubble_icon ("go-previous-symbolic", _("Back (Alt+Left)"), () => go_back ());
            search_switcher = new BubbleSwitcher ();
            search_switcher.add_option ("name", _("Name"));
            search_switcher.add_option ("tag", _("Genre"));
            search_switcher.add_option ("country", _("Country"));
            search_switcher.add_option ("language", _("Language"));
            search_switcher.set_active (search_mode);
            search_switcher.selected.connect ((m) => {
                if (m == search_mode) return;
                search_mode = m;
                run_search ();
            });
            search_switcher.visible = false;
            add_bubble_widget (search_switcher);
            search = add_bubble_search (_("Search Stations"), (t) => schedule_search ());
            search.entry.activate.connect (() => {
                if (search_timer != 0) Source.remove (search_timer);
                search_timer = 0;
                run_search ();
            });
            add_bubble_icon ("list-add-symbolic", _("Add Custom Station (Ctrl+N)"), () => edit_custom (null));

            install_actions ();
            library.changed.connect (on_library_changed);
            songs.changed.connect (() => {
                update_actions ();
                if (view != null && view.kind == "history") {
                    view.scroll = scroll.vadjustment.value;
                    render ();
                }
            });
            alarms.changed.connect (() => {
                update_actions ();
                if (view != null && view.kind == "alarms") render ();
            });
            sleep.changed.connect (sync_sleep);
            sleep.notify["active"].connect (update_actions);
            player.notify["state"].connect (sync_player);
            player.notify["buffer-percent"].connect (sync_player);
            player.metadata_changed.connect (sync_player);
            app.mpris.player.open_requested.connect ((uri) => play_address (uri));
            player.notify["volume"].connect (() => {
                sync_volume ();
                schedule_save ();
            });
            NetworkMonitor.get_default ().network_changed.connect ((available) => {
                if (available && load_failed && view != null) Idle.add (() => {
                    render ();
                    return Source.REMOVE;
                });
            });

            double vol = 0.8;
            try {
                vol = state.get_double ("Player", "volume");
            } catch (Error e) {
            }
            player.volume = vol;
            string last = "";
            try {
                last = state.get_string ("Player", "station");
            } catch (Error e) {
            }
            if (last != "" && player.station == null) {
                var s = library.find (last);
                if (s != null) player.cue (s);
            }
            sync_player ();
            close_request.connect (() => {
                save_state ();
                return false;
            });
            string start = "library";
            try {
                start = state.get_string ("View", "page");
            } catch (Error e) {
            }
            navigate_root (start);
        }

        private static string locale_country () {
            foreach (string name in Intl.get_language_names ()) {
                string n = name.split (".")[0].split ("@")[0];
                int u = n.index_of ("_");
                if (u > 0 && n.length - u - 1 == 2) return n.substring (u + 1).up ();
            }
            return "";
        }

        private void build_sidebar () {
            add_nav ("library", "folder-music-symbolic", _("Library"));
            add_nav ("recent", "document-open-recent-symbolic", _("Recently Played"));
            add_nav ("history", "view-list-symbolic", _("History"));
            add_nav ("alarms", "alarm-symbolic", _("Alarms"));
            sidebar.box.append (new SidebarSectionLabel (_("Discover")));
            add_nav ("popular", "network-wireless-signal-excellent-symbolic", _("Popular"));
            if (local_code != "") add_nav ("local", "mark-location-symbolic", _("Near You"));
            add_nav ("genres", "audio-x-generic-symbolic", _("Genres"));
            add_nav ("countries", "emoji-flags-symbolic", _("Countries"));
            add_nav ("languages", "preferences-desktop-locale-symbolic", _("Languages"));
        }

        private void add_nav (string id, string icon, string label) {
            var row = new SidebarRow (icon, label);
            row.clicked.connect (() => navigate_root (id));
            nav_rows[id] = row;
            sidebar.box.append (row);
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.radio";
            wp.title = _("Radio");
            wp.subtitle = _("Listen to thousands of stations from around the world. The stations you add are kept in your library.");
            wp.add_action ("network-workgroup", _("Browse Stations"), _("Popular stations, genres and countries"), () => navigate_root ("popular"));
            wp.add_action ("audio-x-generic", _("Add Custom Station"), _("Listen to a stream by its address"), () => edit_custom (null));
            return wp;
        }

        private Widget build_bar () {
            var bar = new Box (Orientation.HORIZONTAL, 12);
            bar.add_css_class ("radio-bar");
            bar_art = new StationArt (44);
            bar_art.valign = Align.CENTER;
            var art_click = new GestureClick ();
            art_click.released.connect (() => {
                if (player.station != null) open_detail (player.station);
            });
            bar_art.add_controller (art_click);
            bar_art.cursor = new Gdk.Cursor.from_name ("pointer", null);
            bar.append (bar_art);

            var texts = new Box (Orientation.VERTICAL, 2);
            texts.valign = Align.CENTER;
            texts.hexpand = true;
            bar_title = new Label ("");
            bar_title.add_css_class ("radio-bar-title");
            bar_title.xalign = 0;
            bar_title.ellipsize = Pango.EllipsizeMode.END;
            texts.append (bar_title);
            bar_status = new Label ("");
            bar_status.add_css_class ("radio-bar-status");
            bar_status.xalign = 0;
            bar_status.ellipsize = Pango.EllipsizeMode.END;
            bar_status.selectable = true;
            bar_status.can_focus = false;
            texts.append (bar_status);
            bar.append (texts);

            bar_info = new Label ("");
            bar_info.add_css_class ("radio-bar-info");
            bar_info.add_css_class ("dim-label");
            bar_info.valign = Align.CENTER;
            bar.append (bar_info);

            bar_star = new Button.from_icon_name ("non-starred-symbolic");
            bar_star.add_css_class ("flat");
            bar_star.add_css_class ("radio-round");
            bar_star.valign = Align.CENTER;
            bar_star.clicked.connect (() => {
                if (player.station != null) library.toggle_favorite (player.station);
            });
            bar.append (bar_star);

            bar_sleep = new Button ();
            bar_sleep.add_css_class ("flat");
            bar_sleep.add_css_class ("radio-sleep");
            bar_sleep.valign = Align.CENTER;
            var sleep_box = new Box (Orientation.HORIZONTAL, 6);
            sleep_box.append (new Image.from_icon_name ("weather-clear-night-symbolic"));
            bar_sleep_label = new Label ("");
            bar_sleep_label.add_css_class ("radio-bar-info");
            bar_sleep_label.visible = false;
            sleep_box.append (bar_sleep_label);
            bar_sleep.child = sleep_box;
            bar_sleep.tooltip_text = _("Sleep Timer");
            bar_sleep.update_property (AccessibleProperty.LABEL, _("Sleep Timer"), -1);
            bar_sleep.clicked.connect (() => sleep_menu ());
            bar.append (bar_sleep);

            var stop = new Button.from_icon_name ("media-playback-stop-symbolic");
            stop.add_css_class ("flat");
            stop.add_css_class ("radio-round");
            stop.valign = Align.CENTER;
            stop.tooltip_text = _("Stop");
            stop.clicked.connect (() => player.stop ());
            bar.append (stop);

            bar_play = new Button.from_icon_name ("media-playback-start-symbolic");
            bar_play.add_css_class ("suggested-action");
            bar_play.add_css_class ("radio-play");
            bar_play.valign = Align.CENTER;
            bar_play.clicked.connect (() => toggle_play ());
            bar.append (bar_play);

            bar_mute = new Button.from_icon_name ("audio-volume-high-symbolic");
            bar_mute.add_css_class ("flat");
            bar_mute.add_css_class ("radio-round");
            bar_mute.valign = Align.CENTER;
            bar_mute.clicked.connect (() => {
                player.muted = !player.muted;
                sync_volume ();
            });
            bar.append (bar_mute);

            bar_volume = new Scale.with_range (Orientation.HORIZONTAL, 0, 1, 0.05);
            bar_volume.add_css_class ("radio-volume");
            bar_volume.draw_value = false;
            bar_volume.valign = Align.CENTER;
            bar_volume.tooltip_text = _("Volume");
            bar_volume.update_property (AccessibleProperty.LABEL, _("Volume"), -1);
            bar_volume.value_changed.connect (() => {
                if (syncing_volume) return;
                player.volume = bar_volume.get_value ();
                if (player.muted) player.muted = false;
                sync_volume ();
                schedule_save ();
            });
            bar.append (bar_volume);

            bar_reveal = new Revealer ();
            bar_reveal.transition_type = RevealerTransitionType.SLIDE_UP;
            bar_reveal.child = bar;
            return bar_reveal;
        }

        private void sync_volume () {
            syncing_volume = true;
            bar_volume.set_value (player.volume);
            syncing_volume = false;
            string icon = "audio-volume-high-symbolic";
            if (player.muted || player.volume <= 0.001) icon = "audio-volume-muted-symbolic";
            else if (player.volume < 0.34) icon = "audio-volume-low-symbolic";
            else if (player.volume < 0.67) icon = "audio-volume-medium-symbolic";
            bar_mute.icon_name = icon;
            bar_mute.tooltip_text = player.muted ? _("Unmute") : _("Mute");
            app.mpris.player.volume_changed ();
        }

        private string status_text (out bool is_error) {
            is_error = false;
            switch (player.state) {
                case PlayState.CONNECTING: return _("Connecting…");
                case PlayState.BUFFERING: return player.buffer_percent > 0 ? _("Buffering %d%%").printf (player.buffer_percent) : _("Buffering…");
                case PlayState.PAUSED: return player.now_playing != "" ? _("Paused · %s").printf (player.now_playing) : _("Paused");
                case PlayState.FAILED:
                    is_error = true;
                    return player.failure;
                case PlayState.PLAYING:
                    if (player.now_playing != "") return player.now_playing;
                    string loc = player.station != null ? player.station.location () : "";
                    return loc != "" ? _("Live from %s").printf (loc) : _("Live");
                default: return "";
            }
        }

        private void sync_player () {
            var s = player.station;
            bar_reveal.reveal_child = s != null;
            if (s != null) {
                bar_art.show_station (s, favicons);
                bar_title.label = s.name;
                bool err;
                bar_status.label = status_text (out err);
                if (err) bar_status.add_css_class ("error");
                else bar_status.remove_css_class ("error");
                bar_status.tooltip_text = bar_status.label;
                bar_info.label = player.state == PlayState.PLAYING ? player.stream_info : "";
                bool active = player.is_active ();
                bar_play.icon_name = active ? "media-playback-pause-symbolic" : (player.state == PlayState.FAILED ? "view-refresh-symbolic" : "media-playback-start-symbolic");
                bar_play.tooltip_text = active ? _("Pause") : (player.state == PlayState.FAILED ? _("Try Again") : _("Play"));
                bool fav = library.is_favorite (s);
                bar_star.icon_name = fav ? "starred-symbolic" : "non-starred-symbolic";
                bar_star.tooltip_text = fav ? _("Remove from Library") : _("Add to Library");
                string? file = s.favicon != "" ? favicons.cached_file (s.favicon) : null;
                app.mpris.player.set_art (file != null ? File.new_for_path (file).get_uri () : "");
            }
            app.mpris.player.can_switch = library.favorites.size > 1 || library.recent.size > 1;
            app.mpris.player.refresh ();
            foreach (var r in row_refs) sync_row (r);
            update_actions ();
            schedule_save ();
        }

        private void sync_row (RowRef r) {
            bool current = player.station != null && player.station.key () == r.station.key ();
            bool active = current && player.is_active ();
            r.play.icon_name = active ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            r.play.tooltip_text = active ? _("Pause") : _("Play");
            if (current) r.row.add_css_class ("radio-row-playing");
            else r.row.remove_css_class ("radio-row-playing");
            bool fav = library.is_favorite (r.station);
            r.star.icon_name = fav ? "starred-symbolic" : "non-starred-symbolic";
            r.star.tooltip_text = fav ? _("Remove from Library") : _("Add to Library");
            r.play.update_property (AccessibleProperty.LABEL, r.play.tooltip_text, -1);
            r.star.update_property (AccessibleProperty.LABEL, r.star.tooltip_text, -1);
        }

        private void on_library_changed () {
            if (library.error != "") show_error (_("The Library Could Not Be Saved"), library.error);
            sync_player ();
            if (view != null && (view.kind == "library" || view.kind == "recent")) {
                view.scroll = scroll.vadjustment.value;
                render ();
            } else if (view != null && view.kind == "detail") {
                render ();
            }
        }

        private void schedule_save () {
            if (save_id != 0) Source.remove (save_id);
            save_id = Timeout.add (1200, () => {
                save_id = 0;
                save_state ();
                return Source.REMOVE;
            });
        }

        private void save_state () {
            state.set_double ("Player", "volume", player.volume);
            state.set_string ("Player", "station", player.station != null && library.find (player.station.key ()) != null ? player.station.key () : "");
            string root = view != null ? view.nav : "library";
            if (root == "search" || root == "") root = "library";
            state.set_string ("View", "page", root);
            DirUtils.create_with_parents (Path.get_dirname (state_path), 0700);
            try {
                state.save_to_file (state_path);
            } catch (Error e) {
            }
        }

        private View make_root (string id) {
            var v = new View ();
            v.kind = id;
            v.nav = id;
            switch (id) {
                case "recent":
                    v.title = _("Recently Played");
                    break;
                case "history":
                    v.title = _("History");
                    break;
                case "alarms":
                    v.title = _("Alarms");
                    break;
                case "popular":
                    v.title = _("Popular");
                    v.subtitle = _("The most listened stations right now");
                    v.kind = "stations";
                    v.query = new Query ();
                    v.query.order = "clickcount";
                    break;
                case "local":
                    v.title = _("Near You");
                    v.kind = "stations";
                    v.query = new Query ();
                    v.query.country_code = local_code;
                    v.subtitle = _("Popular stations in your country");
                    break;
                case "genres":
                    v.title = _("Genres");
                    v.kind = "facets";
                    break;
                case "countries":
                    v.title = _("Countries");
                    v.kind = "facets";
                    break;
                case "languages":
                    v.title = _("Languages");
                    v.kind = "facets";
                    break;
                default:
                    v.kind = "library";
                    v.nav = "library";
                    v.title = _("Library");
                    break;
            }
            return v;
        }

        public void navigate_root (string id) {
            if (id == "local" && local_code == "") id = "popular";
            history.clear ();
            if (search.text != "") {
                search_timer_cancel ();
                search.clear ();
                search_timer_cancel ();
            }
            show_view (make_root (id));
        }

        private void push (View v) {
            if (view != null) {
                view.scroll = scroll.vadjustment.value;
                history.add (view);
            }
            show_view (v);
        }

        private void go_back () {
            if (history.size == 0) return;
            var v = history.remove_at (history.size - 1);
            if (view != null && view.kind == "search" && v.kind != "search" && search.text != "") {
                search.clear ();
                search_timer_cancel ();
            }
            show_view (v);
        }

        private void show_view (View v) {
            view = v;
            foreach (var e in nav_rows.entries) e.value.set_active (e.key == v.nav);
            back_bubble.visible = history.size > 0;
            search_switcher.visible = v.kind == "search";
            update_actions ();
            search_switcher.set_active (search_mode);
            render ();
        }

        private void clear_page () {
            if (detail_handler != 0) player.disconnect (detail_handler);
            detail_handler = 0;
            row_refs.clear ();
            Widget? c;
            while ((c = page.get_first_child ()) != null) page.remove (c);
        }

        private void render () {
            if (loading != null) loading.cancel ();
            loading = null;
            load_failed = false;
            clear_page ();
            if (view.kind == "library" && library.favorites.size == 0) {
                stack.visible_child_name = "welcome";
                return;
            }
            if (view.kind == "alarms" && alarms.available && alarms.alarms ().size == 0) {
                stack.visible_child_name = "alarms-empty";
                return;
            }
            stack.visible_child_name = "page";
            switch (view.kind) {
                case "library":
                    render_library ();
                    break;
                case "recent":
                    render_recent ();
                    break;
                case "history":
                    render_history ();
                    break;
                case "alarms":
                    render_alarms ();
                    break;
                case "facets":
                    render_facets ();
                    break;
                case "detail":
                    render_detail ();
                    break;
                default:
                    render_stations ();
                    break;
            }
        }

        private void restore_scroll () {
            double target = view.scroll;
            var v = view;
            if (target <= 0) {
                scroll.vadjustment.value = 0;
                return;
            }
            Idle.add (() => {
                if (view == v) scroll.vadjustment.value = target;
                return Source.REMOVE;
            });
        }

        private Box header (string title, string subtitle, Widget? suffix = null) {
            var head = new Box (Orientation.HORIZONTAL, 12);
            head.margin_top = 8;
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            var t = new Label (title);
            t.add_css_class ("radio-page-title");
            t.xalign = 0;
            t.wrap = true;
            texts.append (t);
            if (subtitle != "") {
                var s = new Label (subtitle);
                s.add_css_class ("dim-label");
                s.xalign = 0;
                s.wrap = true;
                texts.append (s);
            }
            head.append (texts);
            if (suffix != null) {
                suffix.valign = Align.CENTER;
                head.append (suffix);
            }
            return head;
        }

        private StatusPage status (string title, string description, string? action = null, owned WelcomePage.ActionCallback? callback = null) {
            var sp = new StatusPage ();
            sp.icon_name = "dev.sinty.radio";
            sp.title = title;
            sp.description = description;
            sp.vexpand = true;
            if (action != null && callback != null) {
                WelcomePage.ActionCallback cb = (owned) callback;
                var b = new Button.with_label (action);
                b.add_css_class ("pill");
                b.add_css_class ("suggested-action");
                b.halign = Align.CENTER;
                b.clicked.connect (() => cb ());
                sp.child = b;
            }
            return sp;
        }

        private WelcomePage nothing_yet (string title, string subtitle) {
            var wp = new WelcomePage ();
            wp.is_section = true;
            wp.embedded = true;
            wp.vexpand = true;
            wp.app_icon_name = "dev.sinty.radio";
            wp.title = title;
            wp.subtitle = subtitle;
            wp.add_action ("network-workgroup", _("Browse Stations"), _("Popular stations, genres and countries"), () => navigate_root ("popular"));
            if (local_code != "") wp.add_action ("find-location", _("Stations Near You"), _("Local stations from your country"), () => navigate_root ("local"));
            wp.add_action ("system-search", _("Search Stations"), _("Find a station by name, genre or language"), () => search.grab_focus_entry ());
            return wp;
        }

        private Widget spinner_box (string text) {
            var box = new Box (Orientation.VERTICAL, 12);
            box.valign = Align.CENTER;
            box.halign = Align.CENTER;
            box.vexpand = true;
            box.margin_top = 48;
            var sp = new Spinner ();
            sp.spinning = true;
            sp.set_size_request (32, 32);
            box.append (sp);
            var l = new Label (text);
            l.add_css_class ("dim-label");
            box.append (l);
            return box;
        }

        private ListBox station_list (Gee.List<Station> stations, bool in_library = false) {
            var list = new ListBox ();
            list.add_css_class ("radio-list");
            list.selection_mode = SelectionMode.NONE;
            foreach (var s in stations) list.append (station_row (s, in_library));
            list.row_activated.connect ((row) => {
                var s = row.get_data<Station> ("station");
                if (s != null) open_detail (s);
            });
            return list;
        }

        private ListBoxRow station_row (Station s, bool in_library) {
            var row = new ListBoxRow ();
            row.set_data<Station> ("station", s);
            var box = new Box (Orientation.HORIZONTAL, 12);
            var art = new StationArt (44);
            art.valign = Align.CENTER;
            art.show_station (s, favicons);
            box.append (art);
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            var name = new Label (s.name);
            name.add_css_class ("radio-row-name");
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.END;
            texts.append (name);
            string sub = s.custom ? Station.host_of (s.stream_url ()) : s.subtitle ();
            if (sub != "") {
                var l = new Label (sub);
                l.add_css_class ("dim-label");
                l.add_css_class ("caption");
                l.xalign = 0;
                l.ellipsize = Pango.EllipsizeMode.END;
                texts.append (l);
            }
            box.append (texts);
            var star = new Button.from_icon_name ("non-starred-symbolic");
            star.add_css_class ("flat");
            star.add_css_class ("radio-round");
            star.valign = Align.CENTER;
            star.clicked.connect (() => library.toggle_favorite (s));
            box.append (star);
            var play = new Button.from_icon_name ("media-playback-start-symbolic");
            play.add_css_class ("flat");
            play.add_css_class ("radio-round");
            play.valign = Align.CENTER;
            play.clicked.connect (() => {
                if (player.station != null && player.station.key () == s.key () && player.is_active ()) player.pause ();
                else play_station (s);
            });
            box.append (play);
            row.child = box;
            row.update_property (AccessibleProperty.LABEL, s.name, -1);
            var r = new RowRef ();
            r.station = s;
            r.row = row;
            r.play = play;
            r.star = star;
            row_refs.add (r);
            sync_row (r);
            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => station_menu (row, s, x, y, in_library));
            row.add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => station_menu (row, s, x, y, in_library));
            row.add_controller (press);
            return row;
        }

        private void popup_menu (ContextMenu menu, double x, double y) {
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void station_menu (Widget anchor, Station s, double x, double y, bool in_library) {
            var menu = new ContextMenu (anchor);
            bool current = player.station != null && player.station.key () == s.key () && player.is_active ();
            menu.add_item (current ? _("Pause") : _("Play"), current ? "media-playback-pause-symbolic" : "media-playback-start-symbolic", () => {
                if (current) player.pause ();
                else play_station (s);
            });
            menu.add_item (_("Details"), "view-more-symbolic", () => open_detail (s));
            bool fav = library.is_favorite (s);
            menu.add_item (fav ? _("Remove from Library") : _("Add to Library"), fav ? "non-starred-symbolic" : "starred-symbolic", () => library.toggle_favorite (s));
            menu.add_item (_("Copy Stream Address"), "edit-copy-symbolic", () => get_clipboard ().set_text (s.stream_url ()));
            if (s.custom) menu.add_item (_("Edit"), "document-edit-symbolic", () => edit_custom (s));
            if (in_library && fav && library.favorites.size > 1) {
                int idx = library.favorites.index_of (s);
                menu.add_separator ();
                if (idx > 0) menu.add_item (_("Move Up"), "go-up-symbolic", () => library.move_favorite (s, idx - 1));
                if (idx >= 0 && idx < library.favorites.size - 1) menu.add_item (_("Move Down"), "go-down-symbolic", () => library.move_favorite (s, idx + 1));
            }
            popup_menu (menu, x, y);
        }

        private void render_library () {
            int n = library.favorites.size;
            page.append (header (_("Library"), ngettext ("%d station", "%d stations", n).printf (n)));
            page.append (station_list (library.favorites, true));
            restore_scroll ();
        }

        private void render_recent () {
            Button? clear = null;
            if (library.recent.size > 0) {
                clear = new Button.with_label (_("Clear"));
                clear.add_css_class ("pill");
                clear.clicked.connect (() => confirm_clear_recent ());
            }
            page.append (header (_("Recently Played"), "", clear));
            if (library.recent.size == 0) {
                page.append (nothing_yet (_("Nothing Played Yet"), _("The stations you listen to appear here.")));
                return;
            }
            page.append (station_list (library.recent));
            restore_scroll ();
        }

        private void confirm_clear_recent () {
            var dlg = new ConfirmDialog (app, _("Clear Recently Played?"), "edit-clear-all-symbolic",
                _("The list of stations you listened to is emptied. Your library is kept."), _("Clear"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) library.clear_recent ();
            });
            dlg.present ();
        }

        private void render_stations () {
            var v = view;
            page.append (header (v.title, v.subtitle));
            if (v.results != null) {
                show_results (v);
                restore_scroll ();
                return;
            }
            var spin = spinner_box (_("Finding stations…"));
            page.append (spin);
            var cancel = new Cancellable ();
            loading = cancel;
            directory.search.begin (v.query, cancel, (o, res) => {
                if (cancel.is_cancelled () || view != v) return;
                loading = null;
                try {
                    var list = directory.search.end (res);
                    v.results = new Gee.ArrayList<Station> ();
                    v.results.add_all (list);
                    v.more = list.size >= v.query.limit;
                    page.remove (spin);
                    show_results (v);
                } catch (Error e) {
                    page.remove (spin);
                    show_load_error (e);
                }
            });
        }

        private void show_load_error (Error e) {
            load_failed = true;
            bool offline = e is DirectoryError.OFFLINE;
            page.append (status (offline ? _("You Are Offline") : _("Stations Are Not Available"), e.message, _("Try Again"), () => render ()));
        }

        private void show_results (View v) {
            if (v.results.size == 0) {
                string desc = v.kind == "search" ? _("Try another name, or search by genre, country or language.") : _("There are no stations here right now.");
                page.append (status (_("No Stations Found"), desc, _("Browse Stations"), () => navigate_root ("popular")));
                return;
            }
            var list = station_list (v.results);
            page.append (list);
            if (!v.more) return;
            var more = new Button.with_label (_("Show More"));
            more.add_css_class ("pill");
            more.halign = Align.CENTER;
            more.margin_top = 4;
            page.append (more);
            more.clicked.connect (() => {
                more.sensitive = false;
                more.label = _("Loading…");
                var q = new Query ();
                q.name = v.query.name;
                q.tag = v.query.tag;
                q.country = v.query.country;
                q.country_code = v.query.country_code;
                q.language = v.query.language;
                q.order = v.query.order;
                q.reverse = v.query.reverse;
                q.limit = v.query.limit;
                q.offset = v.results.size;
                var cancel = new Cancellable ();
                loading = cancel;
                directory.search.begin (q, cancel, (o, res) => {
                    if (cancel.is_cancelled () || view != v) return;
                    loading = null;
                    try {
                        var extra = directory.search.end (res);
                        var known = new Gee.HashSet<string> ();
                        foreach (var s in v.results) known.add (s.key ());
                        foreach (var s in extra) {
                            if (known.contains (s.key ())) continue;
                            v.results.add (s);
                            list.append (station_row (s, false));
                        }
                        v.more = extra.size >= q.limit && v.results.size < 1000;
                        if (v.more) {
                            more.sensitive = true;
                            more.label = _("Show More");
                        } else {
                            page.remove (more);
                        }
                    } catch (Error e) {
                        more.sensitive = true;
                        more.label = _("Try Again");
                        more.tooltip_text = e.message;
                    }
                });
            });
        }

        private void render_facets () {
            var v = view;
            string kind = v.nav == "genres" ? "tags" : v.nav;
            string sub = kind == "tags" ? _("Choose a genre to see its stations") : (kind == "countries" ? _("Choose a country to see its stations") : _("Choose a language to see its stations"));
            page.append (header (v.title, sub));
            if (facet_cache.has_key (kind)) {
                page.append (facet_flow (kind, facet_cache[kind]));
                restore_scroll ();
                return;
            }
            var spin = spinner_box (_("Loading…"));
            page.append (spin);
            var cancel = new Cancellable ();
            loading = cancel;
            directory.facets.begin (kind, cancel, (o, res) => {
                if (cancel.is_cancelled () || view != v) return;
                loading = null;
                page.remove (spin);
                try {
                    var list = directory.facets.end (res);
                    facet_cache[kind] = list;
                    if (list.size == 0) page.append (status (_("Nothing Found"), _("The station directory has no entries here right now."), _("Browse Stations"), () => navigate_root ("popular")));
                    else page.append (facet_flow (kind, list));
                } catch (Error e) {
                    show_load_error (e);
                }
            });
        }

        private static string display_name (string name) {
            if (name.length == 0) return name;
            if (name.down () != name) return name;
            var sb = new StringBuilder ();
            bool up = true;
            unichar c;
            int i = 0;
            while (name.get_next_char (ref i, out c)) {
                sb.append_unichar (up ? c.totitle () : c);
                up = c == ' ' || c == '-' || c == '/';
            }
            return sb.str;
        }

        private Widget facet_flow (string kind, Gee.List<Parse.Facet> facets) {
            var flow = new FlowBox ();
            flow.selection_mode = SelectionMode.NONE;
            flow.column_spacing = 8;
            flow.row_spacing = 8;
            flow.max_children_per_line = 30;
            flow.homogeneous = false;
            flow.valign = Align.START;
            foreach (var f in facets) {
                var chip = new Button ();
                chip.add_css_class ("flat");
                chip.add_css_class ("radio-chip");
                var inner = new Box (Orientation.HORIZONTAL, 6);
                string label = display_name (f.name);
                inner.append (new Label (label));
                var count = new Label (f.count.to_string ());
                count.add_css_class ("radio-chip-count");
                inner.append (count);
                chip.child = inner;
                chip.tooltip_text = ngettext ("%d station", "%d stations", f.count).printf (f.count);
                var facet = f;
                chip.clicked.connect (() => open_facet (kind, facet, label));
                flow.append (chip);
            }
            return flow;
        }

        private void open_facet (string kind, Parse.Facet f, string label) {
            var v = new View ();
            v.kind = "stations";
            v.nav = view.nav;
            v.title = label;
            v.query = new Query ();
            if (kind == "tags") {
                v.query.tag = f.name;
                v.subtitle = _("Genre");
            } else if (kind == "countries") {
                if (f.code != "") v.query.country_code = f.code;
                else v.query.country = f.name;
                v.subtitle = _("Country");
            } else {
                v.query.language = f.name;
                v.subtitle = _("Language");
            }
            push (v);
        }

        private void open_tag (string tag) {
            var f = new Parse.Facet ();
            f.name = tag;
            open_facet ("tags", f, display_name (tag));
        }

        private void open_detail (Station s) {
            if (view != null && view.kind == "detail" && view.station.key () == s.key ()) return;
            var v = new View ();
            v.kind = "detail";
            v.nav = view != null ? view.nav : "library";
            v.station = s;
            v.title = s.name;
            push (v);
        }

        private void render_detail () {
            var s = library.find (view.station.key ()) ?? view.station;
            view.station = s;
            var top = new Box (Orientation.HORIZONTAL, 20);
            top.margin_top = 12;
            var art = new StationArt (144);
            art.valign = Align.START;
            art.show_station (s, favicons);
            top.append (art);
            var info = new Box (Orientation.VERTICAL, 6);
            info.valign = Align.CENTER;
            info.hexpand = true;
            var name = new Label (s.name);
            name.add_css_class ("radio-detail-name");
            name.xalign = 0;
            name.wrap = true;
            name.selectable = true;
            info.append (name);
            string loc = s.location ();
            string sub = s.custom ? _("Custom station") : loc;
            if (sub != "") {
                var l = new Label (sub);
                l.add_css_class ("dim-label");
                l.xalign = 0;
                l.wrap = true;
                info.append (l);
            }
            string[] tags = s.tag_list (8);
            if (tags.length > 0) {
                var chips = new FlowBox ();
                chips.selection_mode = SelectionMode.NONE;
                chips.column_spacing = 6;
                chips.row_spacing = 6;
                chips.max_children_per_line = 8;
                chips.margin_top = 4;
                foreach (string t in tags) {
                    var chip = new Button.with_label (display_name (t));
                    chip.add_css_class ("flat");
                    chip.add_css_class ("radio-chip");
                    string tag = t;
                    chip.clicked.connect (() => open_tag (tag));
                    chips.append (chip);
                }
                info.append (chips);
            }
            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.margin_top = 10;
            bool current = player.station != null && player.station.key () == s.key () && player.is_active ();
            var play = new Button.with_label (current ? _("Pause") : _("Play"));
            play.add_css_class ("pill");
            play.add_css_class ("suggested-action");
            play.clicked.connect (() => {
                if (player.station != null && player.station.key () == s.key () && player.is_active ()) player.pause ();
                else play_station (s);
            });
            detail_handler = player.notify["state"].connect (() => {
                bool on = player.station != null && player.station.key () == s.key () && player.is_active ();
                play.label = on ? _("Pause") : _("Play");
            });
            actions.append (play);
            bool fav = library.is_favorite (s);
            var lib = new Button.with_label (fav ? _("Remove from Library") : _("Add to Library"));
            lib.add_css_class ("pill");
            lib.clicked.connect (() => library.toggle_favorite (s));
            actions.append (lib);
            if (s.custom) {
                var edit = new Button.with_label (_("Edit"));
                edit.add_css_class ("pill");
                edit.clicked.connect (() => edit_custom (s));
                actions.append (edit);
            }
            info.append (actions);
            top.append (info);
            page.append (top);

            var group = new PreferencesGroup (_("Broadcast"));
            string q = s.format_quality ();
            if (q != "") group.add_row (new ActionRow (_("Quality"), q));
            if (s.language.strip () != "") group.add_row (new ActionRow (_("Language"), display_name (s.language.replace (",", ", "))));
            if (loc != "") group.add_row (new ActionRow (_("Location"), loc));
            if (!s.custom && (s.votes > 0 || s.clicks > 0)) {
                group.add_row (new ActionRow (_("Popularity"), _("%s votes · %s plays today").printf (s.votes.to_string (), s.clicks.to_string ())));
            }
            if (s.homepage != "" && Station.is_stream_url (s.homepage)) {
                var row = new ActionRow (_("Website"), s.homepage);
                var open = new Button.from_icon_name ("web-browser-symbolic");
                open.add_css_class ("flat");
                open.valign = Align.CENTER;
                open.tooltip_text = _("Open Website");
                string link = s.homepage;
                open.clicked.connect (() => new UriLauncher (link).launch.begin (this, null));
                row.add_suffix (open);
                group.add_row (row);
            }
            var stream = new ActionRow (_("Stream Address"), s.stream_url ());
            var copy = new Button.from_icon_name ("edit-copy-symbolic");
            copy.add_css_class ("flat");
            copy.valign = Align.CENTER;
            copy.tooltip_text = _("Copy Stream Address");
            copy.clicked.connect (() => get_clipboard ().set_text (s.stream_url ()));
            stream.add_suffix (copy);
            group.add_row (stream);
            page.append (group);
            if (!s.last_check_ok) {
                var warn = new Label (_("The station directory could not reach this stream at its last check. It may not play."));
                warn.add_css_class ("dim-label");
                warn.wrap = true;
                warn.xalign = 0;
                page.append (warn);
            }
            if (!s.custom) {
                var credit = new Label (_("Station information from radio-browser.info"));
                credit.add_css_class ("dim-label");
                credit.add_css_class ("caption");
                credit.xalign = 0;
                page.append (credit);
            }
            scroll.vadjustment.value = 0;
        }

        private void search_timer_cancel () {
            if (search_timer != 0) Source.remove (search_timer);
            search_timer = 0;
        }

        private void schedule_search () {
            search_timer_cancel ();
            search_timer = Timeout.add (450, () => {
                search_timer = 0;
                run_search ();
                return Source.REMOVE;
            });
        }

        private void run_search () {
            string text = search.text.strip ();
            if (text.char_count () < 2) {
                if (text == "" && view != null && view.kind == "search") go_back ();
                return;
            }
            var v = new View ();
            v.kind = "search";
            v.nav = "search";
            v.title = _("Results for “%s”").printf (text);
            v.query = new Query ();
            switch (search_mode) {
                case "tag": v.query.tag = text; break;
                case "country": v.query.country = text; break;
                case "language": v.query.language = text; break;
                default: v.query.name = text; break;
            }
            if (view != null && view.kind == "search") show_view (v);
            else push (v);
        }

        private void play_station (Station s) {
            app.play_station (s);
        }

        private void resume () {
            app.resume ();
        }

        private void toggle_play () {
            if (player.is_active ()) player.pause ();
            else resume ();
        }

        private void step_station (int dir) {
            app.step_station (dir);
        }

        private void play_address (string uri) {
            if (!Station.is_stream_url (uri)) return;
            var s = library.find ("custom:" + uri.strip ());
            if (s == null) {
                s = new Station ();
                s.custom = true;
                s.url = uri.strip ();
                s.name = Station.host_of (s.url);
            }
            play_station (s);
        }

        private void edit_custom (Station? existing) {
            bool is_new = existing == null;
            var dlg = new ConfirmDialog (app, is_new ? _("Add Custom Station") : _("Edit Station"), null,
                is_new ? _("Listen to any internet radio stream by its address. The station is added to your library.") : null,
                is_new ? _("Add") : _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (440, 0);
            var group = new PreferencesGroup (_("Station"));
            var name = new EntryRow (_("Name"));
            var addr = new EntryRow (_("Stream Address"));
            var home = new EntryRow (_("Website"));
            if (existing != null) {
                name.text = existing.name;
                addr.text = existing.url;
                home.text = existing.homepage;
            }
            group.add_row (name);
            group.add_row (addr);
            group.add_row (home);
            dlg.custom_area.append (group);
            var hint = new Label ("");
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.wrap = true;
            hint.max_width_chars = 44;
            dlg.custom_area.append (hint);
            string current_key = existing != null ? existing.key () : "";
            WelcomePage.ActionCallback validate = () => {
                string u = addr.text.strip ();
                bool ok = Station.is_stream_url (u) && Station.host_of (u) != u;
                var dup = ok ? library.find ("custom:" + u) : null;
                if (dup != null && dup.key () != current_key && library.is_favorite (dup)) ok = false;
                dlg.primary_sensitive = ok;
                if (u == "") hint.label = _("For example https://stream.example.org/live.mp3 or a .pls or .m3u playlist.");
                else if (!ok && dup != null) hint.label = _("This stream is already in your library.");
                else if (!ok) hint.label = _("Enter an address that starts with http:// or https://.");
                else hint.label = Parse.is_playlist_url (u) ? _("The playlist is opened when you play the station.") : "";
                hint.visible = hint.label != "";
            };
            addr.entry_changed.connect (() => validate ());
            addr.entry_activated.connect (() => {
                if (!dlg.primary_sensitive) return;
                dlg.response (ConfirmDialog.Response.PRIMARY);
                dlg.close_dialog ();
            });
            validate ();
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                string u = addr.text.strip ();
                if (!Station.is_stream_url (u)) return;
                var s = new Station ();
                s.custom = true;
                s.url = u;
                s.name = name.text.strip () != "" ? Station.clean_text (name.text) : Station.host_of (u);
                string h = home.text.strip ();
                if (h != "" && !h.contains ("://")) h = "https://" + h;
                s.homepage = Station.is_stream_url (h) ? h : "";
                if (existing != null) {
                    int idx = library.favorites.index_of (existing);
                    if (idx >= 0 && existing.key () != s.key ()) {
                        library.favorites.remove_at (idx);
                        library.favorites.insert (idx, s);
                        library.save ();
                    } else if (idx < 0) {
                        library.add_favorite (s);
                    } else {
                        library.update_station (s);
                    }
                    if (view != null && view.kind == "detail") view.station = s;
                    render ();
                } else {
                    library.add_favorite (s);
                    navigate_root ("library");
                }
            });
            dlg.present ();
            if (is_new) addr.grab_focus ();
            else name.grab_focus ();
        }

        public void play_key (string key) {
            var s = library.find (key) ?? alarms.station (key);
            if (s == null) {
                show_error (_("The Station Is Not Available"), _("The station chosen for this alarm is no longer in your library."));
                return;
            }
            player.muted = false;
            sync_volume ();
            play_station (s);
        }

        private void copy_text (string text) {
            get_clipboard ().set_text (text);
        }

        private void search_web (string title) {
            new UriLauncher (History.search_url (app.search_engine (), title)).launch.begin (this, null);
        }

        private void sync_sleep () {
            bool on = sleep.active;
            int left = sleep.remaining ();
            bar_sleep_label.visible = on;
            if (on) {
                bar_sleep.add_css_class ("accent");
                bar_sleep_label.label = left >= 0 ? SleepTimer.format (left) : _("End of song");
                bar_sleep.tooltip_text = left >= 0 ? _("Stops in %s").printf (SleepTimer.format (left)) : _("Stops when the song ends");
            } else {
                bar_sleep.remove_css_class ("accent");
                bar_sleep.tooltip_text = _("Sleep Timer");
            }
        }

        private void sleep_menu () {
            if (!bar_reveal.reveal_child) return;
            var menu = new ContextMenu (bar_sleep);
            foreach (int m in SleepTimer.PRESETS) {
                int minutes = m;
                menu.add_item (ngettext ("%d Minute", "%d Minutes", minutes).printf (minutes), null, () => sleep.start_minutes (minutes));
            }
            if (player.now_playing != "") {
                string song = player.now_playing;
                menu.add_item (_("End of Current Song"), null, () => sleep.start_end_of_song (song));
            }
            menu.add_item (_("Custom…"), null, () => custom_sleep ());
            if (sleep.active) {
                menu.add_separator ();
                menu.add_item (_("Cancel Sleep Timer"), "process-stop-symbolic", () => sleep.cancel ());
            }
            menu.position = PositionType.TOP;
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void custom_sleep () {
            int last = app.settings != null ? app.settings.get_int ("sleep-custom-minutes") : 90;
            var dlg = new ConfirmDialog (app, _("Sleep Timer"), null,
                _("Playback fades out over the last 30 seconds and then stops."), _("Start"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (380, 0);
            var group = new PreferencesGroup (_("Stop After"));
            var minutes = new SpinRow (_("Minutes"), null, 1, 720, 5, last);
            group.add_row (minutes);
            dlg.custom_area.append (group);
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                int m = (int) minutes.value;
                if (app.settings != null) app.settings.set_int ("sleep-custom-minutes", m);
                sleep.start_minutes (m);
            });
            dlg.present ();
        }

        private static string day_label (int64 stamp) {
            var d = new DateTime.from_unix_local (stamp);
            var now = new DateTime.now_local ();
            var today = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
            var day = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), 0, 0, 0);
            int64 diff = today.difference (day) / TimeSpan.DAY;
            if (diff == 0) return _("Today");
            if (diff == 1) return _("Yesterday");
            if (d.get_year () == now.get_year ()) return d.format ("%A %-d %B");
            return d.format ("%-d %B %Y");
        }

        private void render_history () {
            Button? clear = null;
            if (songs.entries.size > 0) {
                clear = new Button.with_label (_("Clear"));
                clear.add_css_class ("pill");
                clear.clicked.connect (() => confirm_clear_history ());
            }
            string sub = app.record_enabled () ? _("Songs announced by the stations you listened to") : _("Songs are not being remembered. Turn this on in Settings.");
            page.append (header (_("History"), sub, clear));
            if (songs.entries.size == 0) {
                page.append (nothing_yet (_("No Songs Yet"), _("The titles that stations announce while you listen appear here.")));
                return;
            }
            PreferencesGroup? group = null;
            string current_day = "";
            foreach (var e in songs.entries) {
                string day = day_label (e.time);
                if (group == null || day != current_day) {
                    current_day = day;
                    group = new PreferencesGroup (day);
                    page.append (group);
                }
                group.add_row (history_row (e));
            }
            restore_scroll ();
        }

        private ActionRow history_row (HistoryEntry e) {
            string when = new DateTime.from_unix_local (e.time).format ("%H:%M");
            var row = new ActionRow (e.title, e.station != "" ? "%s · %s".printf (e.station, when) : when);
            var copy = new Button.from_icon_name ("edit-copy-symbolic");
            copy.add_css_class ("flat");
            copy.valign = Align.CENTER;
            copy.tooltip_text = _("Copy Title");
            copy.update_property (AccessibleProperty.LABEL, _("Copy Title"), -1);
            copy.clicked.connect (() => copy_text (e.title));
            row.add_suffix (copy);
            var find = new Button.from_icon_name ("system-search-symbolic");
            find.add_css_class ("flat");
            find.valign = Align.CENTER;
            find.tooltip_text = _("Search the Web");
            find.update_property (AccessibleProperty.LABEL, _("Search the Web"), -1);
            find.clicked.connect (() => search_web (e.title));
            row.add_suffix (find);
            row.activated.connect (() => search_web (e.title));
            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => history_menu (row, e, x, y));
            row.add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => history_menu (row, e, x, y));
            row.add_controller (press);
            return row;
        }

        private void history_menu (Widget anchor, HistoryEntry e, double x, double y) {
            var menu = new ContextMenu (anchor);
            menu.add_item (_("Copy Title"), "edit-copy-symbolic", () => copy_text (e.title));
            menu.add_item (_("Search the Web"), "system-search-symbolic", () => search_web (e.title));
            var s = library.find (e.station_key);
            if (s != null) menu.add_item (_("Play %s").printf (s.name), "media-playback-start-symbolic", () => play_station (s));
            menu.add_separator ();
            menu.add_item (_("Remove from History"), "user-trash-symbolic", () => songs.remove (e), "destructive");
            popup_menu (menu, x, y);
        }

        private void confirm_clear_history () {
            var dlg = new ConfirmDialog (app, _("Clear History?"), "edit-clear-all-symbolic",
                _("Every song title in the history is removed. This cannot be undone."), _("Clear"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) songs.clear ();
            });
            dlg.present ();
        }

        private Widget build_alarms_welcome () {
            var wp = new WelcomePage ();
            wp.is_section = true;
            wp.app_icon_name = "dev.sinty.radio";
            wp.title = _("Radio Alarms");
            wp.subtitle = _("Wake up to your favorite station. Alarms ring through Clock, even when Radio is closed.");
            wp.add_action ("dev.sinty.clock", _("New Radio Alarm"), _("Choose a station, a time and the days"), () => edit_alarm (null));
            return wp;
        }

        private void render_alarms () {
            if (!alarms.available) {
                page.append (header (_("Alarms"), ""));
                page.append (status (_("Alarms Need Clock"), _("Radio alarms ring through the Clock app. Install Clock to wake up to a station.")));
                return;
            }
            var add = new Button.with_label (_("New Alarm"));
            add.add_css_class ("pill");
            add.add_css_class ("suggested-action");
            add.clicked.connect (() => edit_alarm (null));
            page.append (header (_("Alarms"), _("Alarms ring through Clock, where you can also see them"), add));
            var group = new PreferencesGroup (_("Wake-Up Stations"), _("Radio opens and plays the station when the alarm rings. If Radio cannot be started, Clock rings instead."));
            var now = new DateTime.now_local ();
            foreach (var a in alarms.alarms ()) group.add_row (alarm_row (a, now));
            page.append (group);
            if (alarms.error != "") {
                var warn = new Label (alarms.error);
                warn.add_css_class ("error");
                warn.xalign = 0;
                warn.wrap = true;
                page.append (warn);
            }
        }

        private string alarm_station_name (RadioAlarm a) {
            var s = library.find (a.station_key) ?? alarms.station (a.station_key);
            return s != null ? s.name : _("Unknown station");
        }

        private ActionRow alarm_row (RadioAlarm a, DateTime now) {
            string[] parts = { a.days_text (), alarm_station_name (a) };
            if (a.enabled) {
                var next = RadioAlarm.next_ring (a.hour, a.minute, a.days, now);
                int64 mins = next.difference (now) / TimeSpan.MINUTE;
                if (mins < 60) parts += _("in %d min").printf ((int) mins + 1);
                else if (mins < 24 * 60) parts += _("in %d h %d min").printf ((int) (mins / 60), (int) (mins % 60));
            }
            var row = new ActionRow (a.time_text (), string.joinv (" · ", parts));
            row.add_css_class ("radio-alarm-row");
            if (!a.enabled) row.add_css_class ("dim-label");
            var edit = new Button.from_icon_name ("document-edit-symbolic");
            edit.add_css_class ("flat");
            edit.valign = Align.CENTER;
            edit.tooltip_text = _("Edit");
            edit.update_property (AccessibleProperty.LABEL, _("Edit"), -1);
            edit.clicked.connect (() => edit_alarm (a));
            row.add_suffix (edit);
            var remove = new Button.from_icon_name ("user-trash-symbolic");
            remove.add_css_class ("flat");
            remove.valign = Align.CENTER;
            remove.tooltip_text = _("Delete");
            remove.update_property (AccessibleProperty.LABEL, _("Delete"), -1);
            remove.clicked.connect (() => alarms.remove (a));
            row.add_suffix (remove);
            var toggle = new Switch ();
            toggle.valign = Align.CENTER;
            toggle.active = a.enabled;
            toggle.update_property (AccessibleProperty.LABEL, _("Enabled"), -1);
            toggle.notify["active"].connect (() => {
                if (toggle.active != a.enabled) alarms.set_enabled (a, toggle.active);
            });
            row.add_suffix (toggle);
            row.activated.connect (() => edit_alarm (a));
            return row;
        }

        private void edit_alarm (RadioAlarm? existing) {
            if (!alarms.available) {
                show_error (_("Alarms Need Clock"), _("Radio alarms ring through the Clock app. Install Clock to wake up to a station."));
                return;
            }
            var choices = new Gee.ArrayList<Station> ();
            var seen = new Gee.HashSet<string> ();
            if (existing != null) {
                var cur = library.find (existing.station_key) ?? alarms.station (existing.station_key);
                if (cur != null) {
                    choices.add (cur);
                    seen.add (cur.key ());
                }
            }
            if (existing == null && player.station != null) {
                choices.add (player.station);
                seen.add (player.station.key ());
            }
            foreach (var s in library.favorites) if (seen.add (s.key ())) choices.add (s);
            foreach (var s in library.recent) if (seen.add (s.key ())) choices.add (s);

            var dlg = new ConfirmDialog (app, existing == null ? _("New Radio Alarm") : _("Edit Radio Alarm"), null, null,
                _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (420, 0);
            var picker = new TimePicker (existing != null ? existing.time_text () : "07:00");
            picker.halign = Align.CENTER;
            picker.margin_bottom = 8;
            dlg.custom_area.append (picker);

            var group = new PreferencesGroup (_("Alarm"), choices.size == 0 ? _("Add a station to your library first, then choose it for the alarm.") : _("The alarm is added to Clock, which starts Radio with this station."));
            var station_options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            foreach (var s in choices) {
                var o = new Singularity.Core.AppSettingOption ();
                o.id = s.key ();
                o.label = s.name;
                station_options.add (o);
            }
            string chosen = choices.size > 0 ? choices[0].key () : "";
            var station_row = new SelectionRow.with_options (_("Station"), station_options, chosen);
            station_row.selected.connect ((id) => {
                chosen = id;
                station_row.current_value = id;
                station_row.expanded = false;
            });
            group.add_row (station_row);

            uint days = existing != null ? existing.days : RadioAlarm.WEEKDAYS;
            string[] repeat_ids = { "once", "every", "weekdays", "weekends", "custom" };
            string[] repeat_labels = { _("Once"), _("Every day"), _("Weekdays"), _("Weekends"), _("Custom Days") };
            var repeat_options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            for (int i = 0; i < repeat_ids.length; i++) {
                var o = new Singularity.Core.AppSettingOption ();
                o.id = repeat_ids[i];
                o.label = repeat_labels[i];
                repeat_options.add (o);
            }
            string repeat = days == 0 ? "once" : (days == RadioAlarm.EVERY_DAY ? "every" : (days == RadioAlarm.WEEKDAYS ? "weekdays" : (days == RadioAlarm.WEEKENDS ? "weekends" : "custom")));
            var repeat_row = new SelectionRow.with_options (_("Repeat"), repeat_options, repeat);
            group.add_row (repeat_row);
            var days_row = new ExpanderRow (_("Days"), RadioAlarm.describe_days (days));
            string[] names = { _("Monday"), _("Tuesday"), _("Wednesday"), _("Thursday"), _("Friday"), _("Saturday"), _("Sunday") };
            SwitchRow[] day_rows = {};
            for (int i = 0; i < 7; i++) {
                var dr = new SwitchRow (names[i], null, (days & (RadioAlarm.MONDAY << i)) != 0);
                int bit = i;
                dr.switch_btn.notify["active"].connect (() => {
                    if (dr.active) days |= RadioAlarm.MONDAY << bit;
                    else days &= ~(RadioAlarm.MONDAY << bit);
                    days_row.subtitle = RadioAlarm.describe_days (days);
                });
                days_row.add_row (dr);
                day_rows += dr;
            }
            days_row.visible = repeat == "custom";
            group.add_row (days_row);
            repeat_row.selected.connect ((id) => {
                repeat_row.current_value = id;
                repeat_row.expanded = false;
                uint preset = days;
                switch (id) {
                    case "once": preset = 0; break;
                    case "every": preset = RadioAlarm.EVERY_DAY; break;
                    case "weekdays": preset = RadioAlarm.WEEKDAYS; break;
                    case "weekends": preset = RadioAlarm.WEEKENDS; break;
                    default: break;
                }
                days_row.visible = id == "custom";
                if (id != "custom") {
                    for (int i = 0; i < 7; i++) day_rows[i].active = (preset & (RadioAlarm.MONDAY << i)) != 0;
                    days = preset;
                } else {
                    days_row.expanded = true;
                }
            });
            dlg.custom_area.append (group);
            dlg.primary_sensitive = choices.size > 0;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                Station? pick = null;
                foreach (var s in choices) if (s.key () == chosen) pick = s;
                if (pick == null) return;
                var a = existing ?? new RadioAlarm ();
                string[] hm = picker.time.split (":");
                a.hour = int.parse (hm[0]).clamp (0, 23);
                a.minute = hm.length > 1 ? int.parse (hm[1]).clamp (0, 59) : 0;
                a.days = days & RadioAlarm.EVERY_DAY;
                a.enabled = true;
                alarms.save (a, pick);
                if (alarms.error != "") show_error (_("The Alarm Was Saved, but Clock Did Not Start"), alarms.error);
                navigate_root ("alarms");
            });
            dlg.present ();
        }

        private void show_error (string title, string message) {
            var dlg = new ConfirmDialog.message (app, title, "dialog-error-symbolic", message);
            dlg.transient_for = this;
            dlg.present ();
        }

        public delegate void Handler ();

        private Gee.HashMap<string, SimpleAction> win_actions = new Gee.HashMap<string, SimpleAction> ();

        private void add_win_action (string name, owned Handler handler) {
            var a = new SimpleAction (name, null);
            Handler h = (owned) handler;
            a.activate.connect (() => h ());
            add_action (a);
            win_actions[name] = a;
        }

        private void enable (string name, bool on) {
            var a = win_actions[name];
            if (a != null && a.get_enabled () != on) a.set_enabled (on);
        }

        private void update_actions () {
            if (win_actions.size == 0) return;
            bool has_station = player.station != null;
            bool has_list = library.favorites.size > 0 || library.recent.size > 0;
            Station? target = view != null && view.kind == "detail" ? view.station : player.station;
            enable ("play-pause", has_station || has_list);
            enable ("stop", has_station);
            enable ("previous", has_list);
            enable ("next", has_list);
            enable ("toggle-library", target != null);
            enable ("copy-stream", target != null);
            bool has_song = player.now_playing != "" || songs.entries.size > 0;
            enable ("copy-title", has_song);
            enable ("search-title", has_song);
            enable ("clear-recent", library.recent.size > 0);
            enable ("clear-history", songs.entries.size > 0);
            enable ("back", history.size > 0);
            enable ("show-local", local_code != "");
            enable ("new-alarm", alarms.available);
            enable ("sleep-timer", has_station);
            enable ("cancel-sleep", sleep.active);
            enable ("reload", view != null && view.kind != "library" && view.kind != "recent" && view.kind != "history" && view.kind != "alarms");
        }

        private void install_actions () {
            add_win_action ("add-custom", () => edit_custom (null));
            add_win_action ("find", () => search.grab_focus_entry ());
            add_win_action ("toggle-library", () => {
                Station? s = view != null && view.kind == "detail" ? view.station : player.station;
                if (s != null) library.toggle_favorite (s);
            });
            add_win_action ("copy-stream", () => {
                Station? s = view != null && view.kind == "detail" ? view.station : player.station;
                if (s != null) get_clipboard ().set_text (s.stream_url ());
            });
            add_win_action ("new-alarm", () => edit_alarm (null));
            add_win_action ("copy-title", () => {
                if (player.now_playing != "") copy_text (player.now_playing);
                else if (songs.entries.size > 0) copy_text (songs.entries[0].title);
            });
            add_win_action ("search-title", () => {
                if (player.now_playing != "") search_web (player.now_playing);
                else if (songs.entries.size > 0) search_web (songs.entries[0].title);
            });
            add_win_action ("clear-history", () => {
                if (songs.entries.size > 0) confirm_clear_history ();
            });
            add_win_action ("show-history", () => navigate_root ("history"));
            add_win_action ("show-genres", () => navigate_root ("genres"));
            add_win_action ("show-countries", () => navigate_root ("countries"));
            add_win_action ("show-languages", () => navigate_root ("languages"));
            add_win_action ("close", () => close ());
            add_win_action ("toggle-sidebar", () => set_sidebar_visible (!get_sidebar_visible ()));
            add_win_action ("show-alarms", () => navigate_root ("alarms"));
            add_win_action ("sleep-timer", () => sleep_menu ());
            add_win_action ("cancel-sleep", () => sleep.cancel ());
            add_win_action ("clear-recent", () => {
                if (library.recent.size > 0) confirm_clear_recent ();
            });
            add_win_action ("show-library", () => navigate_root ("library"));
            add_win_action ("show-recent", () => navigate_root ("recent"));
            add_win_action ("show-popular", () => navigate_root ("popular"));
            add_win_action ("show-local", () => navigate_root ("local"));
            add_win_action ("back", () => go_back ());
            add_win_action ("reload", () => {
                if (view == null) return;
                if (view.kind == "facets") facet_cache.unset (view.nav == "genres" ? "tags" : view.nav);
                view.results = null;
                view.scroll = 0;
                render ();
            });
            add_win_action ("play-pause", () => toggle_play ());
            add_win_action ("stop", () => player.stop ());
            add_win_action ("next", () => step_station (1));
            add_win_action ("previous", () => step_station (-1));
            add_win_action ("volume-up", () => {
                player.volume = player.volume + 0.1;
                sync_volume ();
                schedule_save ();
            });
            add_win_action ("volume-down", () => {
                player.volume = player.volume - 0.1;
                sync_volume ();
                schedule_save ();
            });
            add_win_action ("mute", () => {
                player.muted = !player.muted;
                sync_volume ();
            });
            sync_volume ();
            update_actions ();

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, st) => {
                switch (keyval) {
                    case Gdk.Key.AudioPlay:
                    case Gdk.Key.AudioPause:
                        toggle_play ();
                        return true;
                    case Gdk.Key.AudioStop:
                        player.stop ();
                        return true;
                    case Gdk.Key.AudioNext:
                        step_station (1);
                        return true;
                    case Gdk.Key.AudioPrev:
                        step_station (-1);
                        return true;
                    case Gdk.Key.Escape:
                        if (search.text != "") {
                            search.clear ();
                            return true;
                        }
                        if (history.size > 0) {
                            go_back ();
                            return true;
                        }
                        return false;
                    case Gdk.Key.BackSpace:
                        if ((st & Gdk.ModifierType.ALT_MASK) != 0 && history.size > 0) {
                            go_back ();
                            return true;
                        }
                        return false;
                    default:
                        return false;
                }
            });
            ((Widget) this).add_controller (keys);
        }
    }
}
