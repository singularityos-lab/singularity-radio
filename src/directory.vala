namespace Singularity.Apps.Radio {

    public errordomain DirectoryError {
        OFFLINE,
        UNAVAILABLE,
        BAD_ANSWER
    }

    public class Query : Object {
        public string name = "";
        public string tag = "";
        public string country = "";
        public string country_code = "";
        public string language = "";
        public string order = "clickcount";
        public bool reverse = true;
        public int limit = 60;
        public int offset = 0;

        public bool is_empty () {
            return name.strip () == "" && tag.strip () == "" && country.strip () == "" && country_code.strip () == "" && language.strip () == "";
        }

        public string to_path () {
            var sb = new StringBuilder ("/json/stations/search?");
            string[] parts = {};
            if (name.strip () != "") parts += "name=" + Uri.escape_string (name.strip (), null, false);
            if (tag.strip () != "") parts += "tag=" + Uri.escape_string (tag.strip ().down (), null, false);
            if (country.strip () != "") parts += "country=" + Uri.escape_string (country.strip (), null, false);
            if (country_code.strip () != "") parts += "countrycode=" + Uri.escape_string (country_code.strip ().up (), null, false);
            if (language.strip () != "") parts += "language=" + Uri.escape_string (language.strip ().down (), null, false);
            parts += "order=" + Uri.escape_string (order, null, false);
            parts += "reverse=" + (reverse ? "true" : "false");
            parts += "hidebroken=true";
            parts += "offset=%d".printf (int.max (0, offset));
            parts += "limit=%d".printf (limit.clamp (1, 500));
            sb.append (string.joinv ("&", parts));
            return sb.str;
        }
    }

    public class Directory : Object {
        public const string USER_AGENT = "SingularityRadio/0.1 (+https://github.com/singularityos-lab)";
        private const string[] FALLBACK = { "de1.api.radio-browser.info", "nl1.api.radio-browser.info", "at1.api.radio-browser.info", "de2.api.radio-browser.info", "fi1.api.radio-browser.info" };

        private Soup.Session session;
        private string[] servers = {};
        private int current;
        private bool resolving;

        public Directory () {
            session = new Soup.Session ();
            session.user_agent = USER_AGENT;
            session.timeout = 15;
        }

        public Soup.Session http { get { return session; } }

        private static void shuffle (ref string[] list) {
            for (int i = list.length - 1; i > 0; i--) {
                int j = Random.int_range (0, i + 1);
                string t = list[i];
                list[i] = list[j];
                list[j] = t;
            }
        }

        private async string[] resolve_dns () {
            string[] names = {};
            try {
                var resolver = Resolver.get_default ();
                var addrs = yield resolver.lookup_by_name_async ("all.api.radio-browser.info", null);
                foreach (var a in addrs) {
                    try {
                        string host = (yield resolver.lookup_by_address_async (a, null)).strip ().down ();
                        if (host.has_suffix (".")) host = host.substring (0, host.length - 1);
                        if (!host.has_suffix (".api.radio-browser.info")) continue;
                        bool dup = false;
                        foreach (string n in names) if (n == host) dup = true;
                        if (!dup) names += host;
                    } catch (Error e) {
                    }
                }
            } catch (Error e) {
            }
            return names;
        }

        private async void ensure_servers () throws Error {
            if (servers.length > 0) return;
            while (resolving) {
                Timeout.add (50, ensure_servers.callback);
                yield;
            }
            if (servers.length > 0) return;
            resolving = true;
            string[] found = yield resolve_dns ();
            if (found.length == 0) {
                try {
                    var msg = new Soup.Message ("GET", "https://all.api.radio-browser.info/json/servers");
                    var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                    if (msg.status_code == 200) {
                        var parser = new Json.Parser ();
                        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                        found = Parse.servers (parser.get_root ());
                    }
                } catch (Error e) {
                }
            }
            if (found.length == 0) found = FALLBACK;
            shuffle (ref found);
            servers = found;
            current = 0;
            resolving = false;
        }

        public static bool online () {
            return NetworkMonitor.get_default ().network_available;
        }

        public async Json.Node get_json (string path, Cancellable? cancel = null) throws Error {
            if (!online ()) throw new DirectoryError.OFFLINE (_("You are offline. Connect to the internet to find stations."));
            yield ensure_servers ();
            Error? last = null;
            int attempts = int.min (servers.length, 3);
            for (int i = 0; i < attempts; i++) {
                string host = servers[current % servers.length];
                var msg = new Soup.Message ("GET", "https://%s%s".printf (host, path));
                if (msg == null) throw new DirectoryError.BAD_ANSWER (_("The search could not be sent."));
                try {
                    var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
                    if (msg.status_code == 200) {
                        var parser = new Json.Parser ();
                        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                        var root = parser.get_root ();
                        if (root == null) throw new DirectoryError.BAD_ANSWER (_("The station directory sent an empty answer."));
                        return root;
                    }
                    last = new DirectoryError.UNAVAILABLE (_("The station directory answered with an error (HTTP %u).").printf (msg.status_code));
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    last = e;
                }
                current++;
            }
            if (last is DirectoryError) throw last;
            throw new DirectoryError.UNAVAILABLE (_("The station directory cannot be reached. %s").printf (last != null ? last.message : ""));
        }

        public async Gee.List<Station> search (Query q, Cancellable? cancel = null) throws Error {
            return Parse.stations (yield get_json (q.to_path (), cancel));
        }

        public async Gee.List<Station> top (string kind, int limit, Cancellable? cancel = null) throws Error {
            return Parse.stations (yield get_json ("/json/stations/%s/%d?hidebroken=true".printf (kind, limit), cancel));
        }

        public async Gee.List<Parse.Facet> facets (string kind, Cancellable? cancel = null) throws Error {
            string path = "/json/%s?order=stationcount&reverse=true&hidebroken=true".printf (kind);
            if (kind == "tags") path += "&limit=120";
            return Parse.facets (yield get_json (path, cancel), kind == "tags" ? 20 : 1);
        }

        public void count_click (Station s) {
            if (s.uuid == "" || s.custom || !online ()) return;
            ensure_servers.begin ((o, res) => {
                try {
                    ensure_servers.end (res);
                } catch (Error e) {
                    return;
                }
                if (servers.length == 0) return;
                var msg = new Soup.Message ("GET", "https://%s/json/url/%s".printf (servers[current % servers.length], Uri.escape_string (s.uuid, null, false)));
                if (msg == null) return;
                session.send_and_read_async.begin (msg, Priority.LOW, null, (o2, r2) => {
                    try {
                        session.send_and_read_async.end (r2);
                    } catch (Error e) {
                    }
                });
            });
        }

        public async string resolve_stream (string url, Cancellable? cancel = null) throws Error {
            if (!Parse.is_playlist_url (url)) return url;
            var msg = new Soup.Message ("GET", url);
            if (msg == null) throw new DirectoryError.BAD_ANSWER (_("This is not a valid address."));
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
            if (msg.status_code != 200) throw new DirectoryError.UNAVAILABLE (_("The playlist could not be loaded (HTTP %u).").printf (msg.status_code));
            size_t n = size_t.min (bytes.get_size (), 256 * 1024);
            var sb = new StringBuilder.sized (n + 1);
            sb.append_len ((string) bytes.get_data (), (ssize_t) n);
            string text = sb.str;
            string? found = Parse.playlist (text.validate () ? text : text.make_valid ());
            if (found == null) throw new DirectoryError.BAD_ANSWER (_("The playlist does not contain a stream."));
            return found;
        }
    }
}
