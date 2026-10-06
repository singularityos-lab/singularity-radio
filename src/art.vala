using Gtk;

namespace Singularity.Apps.Radio {

    public class Favicons : Object {
        private const int MAX_BYTES = 2 * 1024 * 1024;
        private const int MAX_PARALLEL = 6;
        private const int64 MAX_AGE = 30 * TimeSpan.DAY;
        private const int64 RETRY_AFTER = TimeSpan.DAY;

        private Soup.Session session;
        private string dir;
        private Gee.HashMap<string, Gdk.Texture> memory = new Gee.HashMap<string, Gdk.Texture> ();
        private Gee.HashSet<string> failed = new Gee.HashSet<string> ();
        private Gee.HashMap<string, Gee.ArrayList<SourceFuncWrapper>> waiting = new Gee.HashMap<string, Gee.ArrayList<SourceFuncWrapper>> ();
        private int running;
        private Gee.ArrayQueue<SourceFuncWrapper> queue = new Gee.ArrayQueue<SourceFuncWrapper> ();

        private class SourceFuncWrapper {
            public SourceFunc func;

            public SourceFuncWrapper (owned SourceFunc f) {
                func = (owned) f;
            }
        }

        public Favicons (Soup.Session session) {
            this.session = session;
            dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-radio", "favicons");
            DirUtils.create_with_parents (dir, 0700);
        }

        public string path_for (string url) {
            return Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA256, url.strip ()));
        }

        public string? cached_file (string url) {
            if (url.strip () == "") return null;
            string p = path_for (url);
            try {
                var info = File.new_for_path (p).query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                return info.get_size () > 0 ? p : null;
            } catch (Error e) {
                return null;
            }
        }

        public Gdk.Texture? peek (string url) {
            return memory[url.strip ()];
        }

        private static Gdk.Texture? decode (uint8[] data) {
            try {
                var loader = new Gdk.PixbufLoader ();
                loader.size_prepared.connect ((w, h) => {
                    int m = int.max (w, h);
                    if (m > 256) loader.set_size ((int) Math.round ((double) w * 256 / m), (int) Math.round ((double) h * 256 / m));
                });
                loader.write (data);
                loader.close ();
                var pb = loader.get_pixbuf ();
                if (pb == null || pb.width < 8 || pb.height < 8) return null;
                if (pb.n_channels < 3 || pb.bits_per_sample != 8) return null;
                var fmt = pb.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
                return new Gdk.MemoryTexture (pb.width, pb.height, fmt, pb.read_pixel_bytes (), pb.rowstride);
            } catch (Error e) {
                return null;
            }
        }

        private async void slot () {
            if (running < MAX_PARALLEL) {
                running++;
                return;
            }
            queue.offer (new SourceFuncWrapper (slot.callback));
            yield;
            running++;
        }

        private void release () {
            running--;
            var next = queue.poll ();
            if (next != null) Idle.add ((owned) next.func);
        }

        public async Gdk.Texture? load (string raw_url) {
            string url = raw_url.strip ();
            if (url == "" || !(url.has_prefix ("http://") || url.has_prefix ("https://"))) return null;
            if (memory.has_key (url)) return memory[url];
            if (failed.contains (url)) return null;
            if (waiting.has_key (url)) {
                waiting[url].add (new SourceFuncWrapper (load.callback));
                yield;
                return memory[url];
            }
            waiting[url] = new Gee.ArrayList<SourceFuncWrapper> ();
            var tex = yield fetch (url);
            if (tex != null) memory[url] = tex;
            else failed.add (url);
            var wake = waiting[url];
            waiting.unset (url);
            foreach (var w in wake) Idle.add ((owned) w.func);
            return tex;
        }

        private async Gdk.Texture? fetch (string url) {
            string p = path_for (url);
            var file = File.new_for_path (p);
            int64 now = get_real_time ();
            try {
                var info = yield file.query_info_async ("standard::size,time::modified", FileQueryInfoFlags.NONE, Priority.LOW, null);
                int64 age = now - (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * TimeSpan.SECOND;
                if (info.get_size () == 0 && age < RETRY_AFTER) return null;
                if (info.get_size () > 0 && age < MAX_AGE) {
                    uint8[] data;
                    yield file.load_contents_async (null, out data, null);
                    var t = decode (data);
                    if (t != null) return t;
                }
            } catch (Error e) {
            }
            if (!NetworkMonitor.get_default ().network_available) return null;
            yield slot ();
            Gdk.Texture? tex = null;
            try {
                var msg = new Soup.Message ("GET", url);
                if (msg != null) {
                    msg.request_headers.append ("Accept", "image/*");
                    var stream = yield session.send_async (msg, Priority.LOW, null);
                    if (msg.status_code == 200) {
                        var bytes = yield read_limited (stream);
                        if (bytes != null) {
                            tex = decode (bytes.get_data ());
                            if (tex != null) yield file.replace_contents_async (bytes.get_data (), null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
                        }
                    }
                    try {
                        yield stream.close_async (Priority.LOW, null);
                    } catch (Error e) {
                    }
                }
            } catch (Error e) {
            }
            release ();
            if (tex == null) {
                try {
                    var marker = yield file.replace_async (null, false, FileCreateFlags.REPLACE_DESTINATION, Priority.LOW, null);
                    yield marker.close_async (Priority.LOW, null);
                } catch (Error e) {
                }
            }
            return tex;
        }

        private async Bytes? read_limited (InputStream stream) throws Error {
            var buf = new ByteArray ();
            var chunk = new uint8[16384];
            while (true) {
                ssize_t n = yield stream.read_async (chunk, Priority.LOW, null);
                if (n <= 0) break;
                buf.append (chunk[0:n]);
                if (buf.len > MAX_BYTES) return null;
            }
            return ByteArray.free_to_bytes ((owned) buf);
        }

        public void clear () {
            memory.clear ();
            failed.clear ();
            try {
                var e = File.new_for_path (dir).enumerate_children ("standard::name", FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = e.next_file ()) != null) FileUtils.remove (Path.build_filename (dir, info.get_name ()));
            } catch (Error e) {
            }
        }
    }

    public class StationArt : Widget {
        private Gdk.Texture? texture;
        private Gdk.Paintable? fallback;
        private int size;
        private string url = "";

        public StationArt (int size) {
            this.size = size;
            add_css_class ("radio-art");
            overflow = Overflow.HIDDEN;
            accessible_role = AccessibleRole.IMG;
        }

        public void show_station (Station? s, Favicons icons) {
            string next = s != null ? s.favicon.strip () : "";
            if (next == url && (texture != null || next == "")) return;
            url = next;
            texture = next != "" ? icons.peek (next) : null;
            queue_draw ();
            if (next == "" || texture != null) return;
            icons.load.begin (next, (o, res) => {
                var t = icons.load.end (res);
                if (url != next) return;
                texture = t;
                queue_draw ();
            });
        }

        public override void measure (Orientation o, int for_size, out int minimum, out int natural, out int mb, out int nb) {
            minimum = natural = size;
            mb = nb = -1;
        }

        public override void snapshot (Gtk.Snapshot snap) {
            float w = get_width (), h = get_height ();
            float s = float.min (w, h);
            var rect = Graphene.Rect ().init ((w - s) / 2, (h - s) / 2, s, s);
            var clip = Gsk.RoundedRect ().init_from_rect (rect, float.max (4, s * 0.18f));
            snap.push_rounded_clip (clip);
            if (texture != null) {
                var bg = Gdk.RGBA ();
                bg.parse ("#ffffff");
                snap.append_color (bg, rect);
                float tw = texture.width, th = texture.height;
                float scale = float.min (s / tw, s / th);
                if (tw >= s * 0.8f && th >= s * 0.8f) scale = float.max (s / tw, s / th);
                float dw = tw * scale, dh = th * scale;
                var tr = Graphene.Rect ().init (rect.origin.x + (s - dw) / 2, rect.origin.y + (s - dh) / 2, dw, dh);
                snap.append_scaled_texture (texture, Gsk.ScalingFilter.TRILINEAR, tr);
            } else {
                if (fallback == null) {
                    var theme = IconTheme.get_for_display (get_display ());
                    fallback = theme.lookup_icon ("dev.sinty.radio", null, size, get_scale_factor (), TextDirection.NONE, 0);
                }
                float inset = s * 0.12f;
                snap.save ();
                snap.translate (Graphene.Point () { x = rect.origin.x + inset, y = rect.origin.y + inset });
                fallback.snapshot (snap, s - inset * 2, s - inset * 2);
                snap.restore ();
            }
            snap.pop ();
        }
    }
}
