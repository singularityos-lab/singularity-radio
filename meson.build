project('singularity-radio', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-radio"', language: 'c')
subdir('po')

gtk_dep      = dependency('gtk4')
gee_dep      = dependency('gee-0.8')
soup_dep     = dependency('libsoup-3.0')
json_dep     = dependency('json-glib-1.0')
gst_dep      = dependency('gstreamer-1.0')
gst_audio    = dependency('gstreamer-audio-1.0')
math_dep     = meson.get_compiler('c').find_library('m')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

core_sources = files('src/station.vala', 'src/library.vala', 'src/directory.vala', 'src/history.vala', 'src/sleep_timer.vala', 'src/alarm.vala')

executable('singularity-radio',
  core_sources + files('src/player.vala', 'src/mpris.vala', 'src/art.vala', 'src/alarm_service.vala', 'src/window.vala', 'src/app.vala'),
  dependencies: [gtk_dep, gee_dep, soup_dep, json_dep, gst_dep, gst_audio, math_dep, libsingularity_dep],
  install: true
)

shared_module('singularity-radio-widget',
  files('widget/favorites_widget.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
install_data('widget/dev.sinty.radio.favorites.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

radio_test = executable('radio-test',
  core_sources + files('tests/radio_test.vala'),
  dependencies: [gee_dep, soup_dep, json_dep, dependency('gio-2.0')],
)
test('radio', radio_test, env: [
  'RADIO_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures',
  'TMPDIR=' + meson.current_build_dir(),
])

install_data('data/dev.sinty.radio.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.radio.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.radio.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.radio.service.in',
  output: 'dev.sinty.radio.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/icons/dev.sinty.radio.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
