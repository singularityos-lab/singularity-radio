using Singularity.Apps.Radio;

string fixture_path (string name) {
    return Path.build_filename (Environment.get_variable ("RADIO_FIXTURES"), name);
}

Json.Node load (string name) {
    var p = new Json.Parser ();
    try {
        p.load_from_file (fixture_path (name));
    } catch (Error e) {
        assert_not_reached ();
    }
    return p.get_root ();
}

string text (string name) {
    string t;
    try {
        FileUtils.get_contents (fixture_path (name), out t);
    } catch (Error e) {
        assert_not_reached ();
    }
    return t;
}

void test_stations () {
    var list = Parse.stations (load ("stations.json"));
    assert (list.size == 3);
    var rp = list[0];
    assert (rp.name == "Radio Paradise Main Mix");
    assert (rp.uuid == "96062a7b-0601-11e8-ae97-52543be04c81");
    assert (rp.country_code == "US");
    assert (rp.bitrate == 320 && rp.votes == 32145 && rp.clicks == 1842);
    assert (rp.last_check_ok && !rp.hls);
    string[] tags = rp.tag_list ();
    assert (tags.length == 4);
    assert (tags[0] == "eclectic" && tags[1] == "rock" && tags[2] == "world");
    assert (rp.tag_list (2).length == 2);
    assert (rp.format_quality () == "AAC 320 kbps");
    assert (rp.location () == "California, The United States Of America");
    assert (rp.subtitle () == "eclectic, rock, world · The United States Of America · AAC 320 kbps");

    var dj = list[1];
    assert (dj.stream_url () == "http://example.org/deejay.pls");
    assert (dj.format_quality () == "");
    assert (dj.votes == 12 && dj.clicks == 7);
    assert (dj.hls && !dj.last_check_ok);
    assert (dj.subtitle () == "Italy");

    var anon = list[2];
    assert (anon.name == "icecast.example.net");
    assert (anon.tags == "" && anon.country == "");
    assert (anon.format_quality () == "MP3 128 kbps");

    assert (Parse.stations (new Json.Node (Json.NodeType.NULL)).size == 0);
}

void test_station_json_round_trip () {
    var list = Parse.stations (load ("stations.json"));
    var s = list[0];
    s.custom = false;
    var back = Station.from_json (s.to_json ());
    assert (back != null);
    assert (back.key () == s.key ());
    assert (back.name == s.name && back.favicon == s.favicon && back.tags == s.tags);
    assert (back.bitrate == 320 && back.clicks == 1842 && back.country_code == "US");
    var c = new Station ();
    c.custom = true;
    c.url = "https://stream.example.org/live.mp3";
    c.name = "Mine";
    var c2 = Station.from_json (c.to_json ());
    assert (c2.custom && c2.key () == "custom:https://stream.example.org/live.mp3");
}

void test_servers () {
    string[] names = Parse.servers (load ("servers.json"));
    assert (names.length == 3);
    assert (names[0] == "de1.api.radio-browser.info");
    assert (names[1] == "nl1.api.radio-browser.info");
    assert (names[2] == "at1.api.radio-browser.info");
}

void test_facets () {
    var countries = Parse.facets (load ("countries.json"));
    assert (countries.size == 2);
    assert (countries[0].name == "Germany" && countries[0].code == "DE" && countries[0].count == 5321);
    var tags = Parse.facets (load ("tags.json"), 20);
    assert (tags.size == 2 && tags[1].name == "jazz" && tags[1].code == "");
}

void test_query () {
    var q = new Query ();
    assert (q.is_empty ());
    q.name = " Jazz & Blues ";
    q.country_code = "it";
    q.limit = 9999;
    string p = q.to_path ();
    assert (p.has_prefix ("/json/stations/search?"));
    assert (p.contains ("name=Jazz%20%26%20Blues"));
    assert (p.contains ("countrycode=IT"));
    assert (p.contains ("order=clickcount") && p.contains ("reverse=true") && p.contains ("hidebroken=true"));
    assert (p.contains ("limit=500") && p.contains ("offset=0"));
    assert (!p.contains ("tag=") && !p.contains ("language="));
    assert (!q.is_empty ());
    var t = new Query ();
    t.tag = "Drum and Bass";
    t.offset = 60;
    assert (t.to_path ().contains ("tag=drum%20and%20bass") && t.to_path ().contains ("offset=60"));
}

void test_playlists () {
    assert (Parse.playlist (text ("playlist.pls")) == "http://ice1.example.com:8000/stream");
    assert (Parse.playlist (text ("playlist.m3u")) == "https://example.com/live.aac");
    assert (Parse.playlist (text ("playlist.asx")) == "mms://wm.example.com/radio?a=1&b=2");
    assert (Parse.playlist ("#EXTM3U\n# nothing here\n") == null);
    assert (Parse.playlist ("") == null);
    assert (Parse.is_playlist_url ("http://x.org/listen.PLS?sid=1"));
    assert (Parse.is_playlist_url ("http://x.org/a.m3u"));
    assert (!Parse.is_playlist_url ("http://x.org/a.m3u8"));
    assert (!Parse.is_playlist_url ("http://x.org/stream.mp3"));
}

void test_icy () {
    assert (Icy.clean_title ("StreamTitle='Daft Punk - Around the World';StreamUrl='';") == "Daft Punk - Around the World");
    assert (Icy.clean_title ("StreamTitle='';") == null);
    assert (Icy.clean_title ("  Miles Davis -   So What \n") == "Miles Davis - So What");
    assert (Icy.clean_title (" - Only Title - ") == "Only Title");
    assert (Icy.clean_title ("Unknown - Unknown") == null);
    assert (Icy.clean_title ("Radio Paradise", "radio paradise") == null);
    assert (Icy.clean_title (null) == null);
    string bad = "Caf\xe9 Del Mar";
    string? cleaned = Icy.clean_title (bad);
    assert (cleaned != null && cleaned.validate ());
    string artist, track;
    Icy.split ("Nina Simone - Feeling Good", out artist, out track);
    assert (artist == "Nina Simone" && track == "Feeling Good");
    Icy.split ("Just a Jingle", out artist, out track);
    assert (artist == "" && track == "Just a Jingle");
    Icy.split ("AC-DC - T.N.T. - Live", out artist, out track);
    assert (artist == "AC-DC" && track == "T.N.T. - Live");
}

void test_urls () {
    assert (Station.is_stream_url ("HTTPS://a.b/c"));
    assert (Station.is_stream_url ("rtsp://a.b/c"));
    assert (!Station.is_stream_url ("file:///tmp/x"));
    assert (!Station.is_stream_url ("javascript:alert(1)"));
    assert (Station.host_of ("http://radio.example.com:8000/live") == "radio.example.com");
    assert (Station.clean_text ("\ta\n\n b\u0007c ") == "a bc");
}

void test_library () {
    try {
        run_library ();
    } catch (Error e) {
        error ("library test failed: %s", e.message);
    }
}

void run_library () throws Error {
    string dir = DirUtils.make_tmp ("radio-test-XXXXXX");
    string path = Path.build_filename (dir, "sub", "library.json");
    var lib = new Library (path);
    assert (lib.favorites.size == 0 && lib.recent.size == 0);
    var stations = Parse.stations (load ("stations.json"));
    lib.add_favorite (stations[0]);
    lib.add_favorite (stations[1]);
    lib.add_favorite (stations[0]);
    assert (lib.favorites.size == 2);
    for (int i = 0; i < 3; i++) {
        foreach (var s in stations) lib.played (s);
    }
    assert (lib.recent.size == 3);
    assert (lib.recent[0].key () == stations[2].key ());
    lib.move_favorite (stations[1], 0);

    var again = new Library (path);
    assert (again.error == "");
    assert (again.favorites.size == 2);
    assert (again.favorites[0].key () == stations[1].key ());
    assert (again.is_favorite (stations[0]));
    assert (!again.is_favorite (stations[2]));
    assert (again.recent.size == 3 && again.recent[2].key () == stations[0].key ());
    assert (again.find (stations[2].key ()) != null);
    again.toggle_favorite (stations[0]);
    again.clear_recent ();
    var third = new Library (path);
    assert (third.favorites.size == 1 && third.recent.size == 0);

    for (int i = 0; i < Library.RECENT_LIMIT + 5; i++) {
        var s = new Station ();
        s.custom = true;
        s.url = "http://example.com/%d".printf (i);
        third.played (s);
    }
    assert (third.recent.size == Library.RECENT_LIMIT);
    assert (third.recent[0].url == "http://example.com/%d".printf (Library.RECENT_LIMIT + 4));

    FileUtils.set_contents (path, "{ not json");
    var broken = new Library (path);
    assert (broken.favorites.size == 0 && broken.error != "");
    FileUtils.remove (path);
    DirUtils.remove (Path.build_filename (dir, "sub"));
    DirUtils.remove (dir);
}

void test_history_parse () {
    Gee.List<HistoryEntry> list;
    try {
        list = History.parse (text ("history.json"));
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (list.size == 3);
    assert (list[0].title == "Nina Simone - Feeling Good" && list[0].station_key == "jazz" && list[0].time == 1767261600);
    assert (list[1].station == "Soul Radio");
    assert (list[2].title == "Miles Davis - So What");
    bool thrown = false;
    try {
        History.parse ("{ broken");
    } catch (Error e) {
        thrown = true;
    }
    assert (thrown);
    try {
        assert (History.parse ("[]").size == 0);
        assert (History.parse ("{\"entries\": {}}").size == 0);
    } catch (Error e) {
        assert_not_reached ();
    }
}

void test_history_record () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("radio-history-XXXXXX");
    } catch (Error e) {
        assert_not_reached ();
    }
    string path = Path.build_filename (dir, "history.json");
    var h = new History (path);
    assert (h.entries.size == 0);
    string? title = Icy.clean_title ("StreamTitle='Daft Punk - Around the World';StreamUrl='';");
    assert (h.record (title, "Radio One", "one", 100));
    assert (!h.record ("Daft Punk - Around the World", "Radio One", "one", 101));
    assert (!h.record ("  daft punk -  around the world ", "Radio One", "one", 102));
    assert (h.record ("Daft Punk - Around the World", "Radio Two", "two", 103));
    assert (h.record ("Daft Punk - Around the World", "Radio One", "one", 104));
    assert (!h.record ("   ", "Radio One", "one", 105));
    assert (h.entries.size == 3);
    assert (h.entries[0].time == 104 && h.entries[1].station_key == "two");
    var again = new History (path);
    assert (again.entries.size == 3 && again.entries[0].title == "Daft Punk - Around the World");
    for (int i = 0; i < History.LIMIT + 20; i++) h.record ("Song %d".printf (i), "Radio One", "one", 200 + i);
    assert (h.entries.size == History.LIMIT);
    assert (h.entries[0].title == "Song %d".printf (History.LIMIT + 19));
    var capped = new History (path);
    assert (capped.entries.size == History.LIMIT);
    capped.remove (capped.entries[0]);
    assert (new History (path).entries.size == History.LIMIT - 1);
    capped.clear ();
    assert (new History (path).entries.size == 0);
    try {
        FileUtils.set_contents (path, "{ not json");
    } catch (Error e) {
        assert_not_reached ();
    }
    var broken = new History (path);
    assert (broken.entries.size == 0 && broken.error != "");
    FileUtils.remove (path);
    DirUtils.remove (dir);
}

void test_search_url () {
    assert (History.search_url ("duckduckgo", "AC/DC - T.N.T. & Co") == "https://duckduckgo.com/?q=AC%2FDC%20-%20T.N.T.%20%26%20Co");
    assert (History.search_url ("google", "Café") == "https://www.google.com/search?q=Caf%C3%A9");
    assert (History.search_url ("unknown", "a").has_prefix ("https://duckduckgo.com/"));
    assert (History.search_url ("ecosia", " x ") == "https://www.ecosia.org/search?q=x");
}

void test_sleep_minutes () {
    var t = new SleepTimer (false);
    int expired = 0;
    t.expired.connect (() => expired++);
    int64 start = 1000 * TimeSpan.SECOND;
    t.start_minutes (15, start);
    assert (t.active && t.mode == SleepMode.MINUTES);
    assert (t.remaining (start) == 15 * 60);
    assert (!t.update (start + 10 * TimeSpan.MINUTE));
    assert (t.level == 1.0);
    assert (t.remaining (start + 10 * TimeSpan.MINUTE) == 5 * 60);
    int64 fade_mid = start + 15 * TimeSpan.MINUTE - 15 * TimeSpan.SECOND;
    assert (!t.update (fade_mid));
    assert (Math.fabs (t.level - 0.5) < 0.001);
    assert (!t.update (start + 15 * TimeSpan.MINUTE - 1));
    assert (t.level > 0 && t.level < 0.001);
    assert (t.update (start + 15 * TimeSpan.MINUTE));
    assert (expired == 1 && !t.active && t.level == 1.0);
    assert (!t.update (start + 16 * TimeSpan.MINUTE));
    assert (expired == 1);
    t.start_minutes (30, start);
    t.cancel ();
    assert (!t.active && !t.update (start + 31 * TimeSpan.MINUTE) && expired == 1);
    t.start_minutes (0, start);
    assert (t.remaining (start) == 60);
}

void test_sleep_song () {
    var t = new SleepTimer (false);
    int expired = 0;
    t.expired.connect (() => expired++);
    assert (!t.start_end_of_song (""));
    assert (!t.active);
    assert (t.start_end_of_song ("Artist - Song"));
    int64 at = 50 * TimeSpan.SECOND;
    assert (t.remaining (at) == -1);
    assert (!t.update (at + TimeSpan.HOUR));
    t.song_changed ("Artist - Song", at);
    assert (!t.update (at + TimeSpan.HOUR));
    t.song_changed ("Next - Song", at);
    assert (t.remaining (at) == SleepTimer.SONG_FADE_SECONDS);
    assert (!t.update (at + TimeSpan.SECOND));
    assert (t.level < 1.0 && t.level > 0.5);
    assert (t.update (at + SleepTimer.SONG_FADE_SECONDS * TimeSpan.SECOND));
    assert (expired == 1 && !t.active);
    assert (SleepTimer.fade_level (40 * TimeSpan.SECOND, 30) == 1.0);
    assert (SleepTimer.fade_level (0, 30) == 0.0);
    assert (SleepTimer.format (65) == "1:05" && SleepTimer.format (3725) == "1:02:05" && SleepTimer.format (-3) == "0:00");
}

Variant clock_alarms () {
    var b = new VariantBuilder (new VariantType ("a(siiusb)"));
    b.add ("(siiusb)", "plain", 6, 30, 0u, "Gym", true);
    b.add ("(siiusb)", "radio1", 7, 15, RadioAlarm.WEEKDAYS, "Radio: Jazz FM", true);
    b.add ("(siiusb)", "other", 8, 0, 0u, "Other app", false);
    return b.end ();
}

Variant clock_actions () {
    var b = new VariantBuilder (new VariantType ("a{s(sss)}"));
    b.add ("{s(sss)}", "radio1", "dev.sinty.radio", "play-station", "jazz");
    b.add ("{s(sss)}", "other", "dev.sinty.other", "go", "x");
    b.add ("{s(sss)}", "gone", "dev.sinty.radio", "play-station", "soul");
    return b.end ();
}

void test_alarm_bridge () {
    var list = AlarmBridge.read (clock_alarms (), clock_actions ());
    assert (list.size == 1);
    var a = list[0];
    assert (a.id == "radio1" && a.hour == 7 && a.minute == 15 && a.days == RadioAlarm.WEEKDAYS && a.station_key == "jazz" && a.enabled);
    assert (AlarmBridge.read (new Variant.string ("x"), clock_actions ()).size == 0);

    var n = new RadioAlarm ();
    n.id = "radio2";
    n.hour = 5;
    n.minute = 45;
    n.days = RadioAlarm.WEEKENDS;
    n.label = AlarmBridge.label_for ("Soul Radio");
    n.station_key = "soul";
    var alarms = AlarmBridge.put_alarm (clock_alarms (), n);
    assert (alarms.n_children () == 4);
    var actions = AlarmBridge.link (clock_actions (), alarms, n.id, n.station_key);
    string app, action, target;
    assert (actions.lookup ("radio2", "(sss)", out app, out action, out target));
    assert (app == "dev.sinty.radio" && action == "play-station" && target == "soul");
    assert (!actions.lookup ("gone", "(sss)", out app, out action, out target));
    assert (actions.lookup ("other", "(sss)", out app, out action, out target) && app == "dev.sinty.other");
    list = AlarmBridge.read (alarms, actions);
    assert (list.size == 2 && list[0].id == "radio2" && list[0].label == "Radio: Soul Radio");

    n.hour = 9;
    n.enabled = false;
    alarms = AlarmBridge.put_alarm (alarms, n);
    assert (alarms.n_children () == 4);
    list = AlarmBridge.read (alarms, actions);
    assert (list[1].id == "radio2" && list[1].hour == 9 && !list[1].enabled);

    alarms = AlarmBridge.drop_alarm (alarms, "radio1");
    actions = AlarmBridge.link (actions, alarms, "radio1", null);
    assert (alarms.n_children () == 3);
    assert (!actions.lookup ("radio1", "(sss)", out app, out action, out target));
    list = AlarmBridge.read (alarms, actions);
    assert (list.size == 1 && list[0].id == "radio2");
    assert (AlarmBridge.link (actions, alarms, "missing", "jazz").lookup ("missing", "(sss)", out app, out action, out target) == false);
}

void test_alarm_days () {
    assert (RadioAlarm.describe_days (0) == "Once");
    assert (RadioAlarm.describe_days (RadioAlarm.EVERY_DAY) == "Every day");
    assert (RadioAlarm.describe_days (RadioAlarm.WEEKDAYS) == "Weekdays");
    assert (RadioAlarm.describe_days (RadioAlarm.WEEKENDS) == "Weekends");
    assert (RadioAlarm.describe_days (RadioAlarm.MONDAY | (RadioAlarm.MONDAY << 3)) == "Mon, Thu");
    var fri = new DateTime.local (2026, 9, 25, 8, 0, 0);
    var next = RadioAlarm.next_ring (7, 0, RadioAlarm.WEEKDAYS, fri);
    assert (next.get_day_of_month () == 28 && next.get_hour () == 7);
    next = RadioAlarm.next_ring (9, 30, 0, fri);
    assert (next.get_day_of_month () == 25 && next.get_minute () == 30);
    next = RadioAlarm.next_ring (8, 0, RadioAlarm.MONDAY << 4, fri);
    assert (next.get_month () == 10 && next.get_day_of_month () == 2);
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.init (ref args);
    Test.add_func ("/radio/stations", test_stations);
    Test.add_func ("/radio/station-json", test_station_json_round_trip);
    Test.add_func ("/radio/servers", test_servers);
    Test.add_func ("/radio/facets", test_facets);
    Test.add_func ("/radio/query", test_query);
    Test.add_func ("/radio/playlists", test_playlists);
    Test.add_func ("/radio/icy", test_icy);
    Test.add_func ("/radio/urls", test_urls);
    Test.add_func ("/radio/library", test_library);
    Test.add_func ("/radio/history-parse", test_history_parse);
    Test.add_func ("/radio/history-record", test_history_record);
    Test.add_func ("/radio/search-url", test_search_url);
    Test.add_func ("/radio/sleep-minutes", test_sleep_minutes);
    Test.add_func ("/radio/sleep-song", test_sleep_song);
    Test.add_func ("/radio/alarm-bridge", test_alarm_bridge);
    Test.add_func ("/radio/alarm-days", test_alarm_days);
    return Test.run ();
}
