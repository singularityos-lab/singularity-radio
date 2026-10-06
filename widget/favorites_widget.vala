using Gtk;
using GLib;
using Singularity;

namespace SingularityRadioWidget {

    public class FavoritesProvider : Object, OverviewWidgetProvider {
        public string id { get { return "radio.favorites"; } }
        public string provider_id { get { return "dev.sinty.radio"; } }
        public string display_name { get { return _("Favorite Stations"); } }
        public string icon_name { get { return "dev.sinty.radio"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[3];
                    _sizes[0] = WidgetSize (2, 1);
                    _sizes[1] = WidgetSize (2, 2);
                    _sizes[2] = WidgetSize (4, 2);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            return new FavoritesInstance (size);
        }
    }

    private class Favorite : Object {
        public string key = "";
        public string name = "";
        public string favicon = "";
    }

    public class FavoritesInstance : Gtk.Box {
        private int logo;
        private bool compact;
        private Gtk.Grid grid;
        private Gtk.Label empty;
        private FileMonitor? monitor;
        private string path;
        private int columns;
        private int rows;

        public FavoritesInstance (WidgetSize size) {
            Object (orientation: Orientation.VERTICAL, spacing: 8);
            add_css_class ("overview-widget-card");
            hexpand = true;
            vexpand = true;
            columns = int.max (size.w + size.w / 2, 2);
            rows = int.max (size.h, 1);
            compact = size.h < 2;
            logo = compact ? 40 : 52;

            var header = new Gtk.Label (_("Favorite Stations"));
            header.add_css_class ("heading");
            header.halign = Align.START;
            header.margin_start = 14;
            header.margin_top = 10;
            append (header);

            grid = new Gtk.Grid ();
            grid.column_homogeneous = true;
            grid.row_homogeneous = true;
            grid.column_spacing = 6;
            grid.row_spacing = 6;
            grid.margin_start = 10;
            grid.margin_end = 10;
            grid.margin_bottom = 10;
            grid.hexpand = true;
            grid.vexpand = true;
            append (grid);

            empty = new Gtk.Label (_("Mark stations as favorites in Radio to play them from here."));
            empty.add_css_class ("dim-label");
            empty.wrap = true;
            empty.justify = Justification.CENTER;
            empty.vexpand = true;
            empty.margin_start = 14;
            empty.margin_end = 14;
            append (empty);

            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "radio", "library.json");
            try {
                monitor = File.new_for_path (path).monitor_file (FileMonitorFlags.NONE);
                monitor.changed.connect ((f, o, ev) => {
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.DELETED) refresh ();
                });
            } catch (Error e) {
                monitor = null;
            }
            refresh ();
        }

        private Gee.List<Favorite> load () {
            var list = new Gee.ArrayList<Favorite> ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return list;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return list;
                var o = root.get_object ();
                if (!o.has_member ("favorites") || o.get_member ("favorites").get_node_type () != Json.NodeType.ARRAY) return list;
                foreach (var n in o.get_array_member ("favorites").get_elements ()) {
                    if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                    var so = n.get_object ();
                    var f = new Favorite ();
                    string uuid = so.get_string_member_with_default ("stationuuid", "");
                    string resolved = so.get_string_member_with_default ("url_resolved", "");
                    string url = resolved != "" ? resolved : so.get_string_member_with_default ("url", "");
                    f.key = uuid != "" ? uuid : "custom:" + url;
                    f.name = so.get_string_member_with_default ("name", "");
                    f.favicon = so.get_string_member_with_default ("favicon", "").strip ();
                    if (f.name.strip () == "") f.name = url;
                    list.add (f);
                }
            } catch (Error e) {
                warning ("radio widget: %s", e.message);
            }
            return list;
        }

        private void refresh () {
            Widget? child;
            while ((child = grid.get_first_child ()) != null) grid.remove (child);
            var favorites = load ();
            empty.visible = favorites.size == 0;
            grid.visible = favorites.size > 0;
            int max = columns * rows;
            for (int i = 0; i < favorites.size && i < max; i++) {
                grid.attach (make_tile (favorites[i]), i % columns, i / columns);
            }
        }

        private Gtk.Widget make_tile (Favorite f) {
            var button = new Gtk.Button ();
            button.add_css_class ("flat");
            button.add_css_class ("overview-widget-tile");
            button.tooltip_text = _("Play %s").printf (f.name);
            var box = new Gtk.Box (Orientation.VERTICAL, 4);
            box.valign = Align.CENTER;
            box.append (make_logo (f));
            if (!compact) {
                var name = new Gtk.Label (f.name);
                name.ellipsize = Pango.EllipsizeMode.END;
                name.max_width_chars = 10;
                name.add_css_class ("caption");
                box.append (name);
            }
            button.child = box;
            string key = f.key;
            button.clicked.connect (() => play (key));
            return button;
        }

        private Gtk.Widget make_logo (Favorite f) {
            var image = new Gtk.Image ();
            image.pixel_size = logo;
            image.icon_name = "dev.sinty.radio";
            if (f.favicon != "") {
                string file = Path.build_filename (Environment.get_user_cache_dir (), "singularity-radio", "favicons",
                    Checksum.compute_for_string (ChecksumType.SHA256, f.favicon));
                if (FileUtils.test (file, FileTest.EXISTS)) {
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_scale (file, logo, logo, true);
                        image.paintable = Gdk.Texture.for_pixbuf (pixbuf);
                    } catch (Error e) {
                    }
                }
            }
            return image;
        }

        private void play (string key) {
            Bus.get.begin (BusType.SESSION, null, (o, res) => {
                try {
                    var bus = Bus.get.end (res);
                    var args = new VariantBuilder (new VariantType ("av"));
                    args.add ("v", new Variant.string (key));
                    bus.call.begin ("dev.sinty.radio", "/dev/sinty/radio", "org.freedesktop.Application", "ActivateAction",
                        new Variant ("(s@av@a{sv})", "play-favorite", args.end (), new VariantBuilder (VariantType.VARDICT).end ()),
                        null, DBusCallFlags.NONE, 10000, null);
                } catch (Error e) {
                    warning ("radio widget: %s", e.message);
                }
            });
        }
    }

    [CCode (cname = "singularity_radio_widget_new")]
    public static Object singularity_radio_widget_new () {
        return new FavoritesProvider ();
    }
}
