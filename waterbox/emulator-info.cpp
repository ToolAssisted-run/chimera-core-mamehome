// chimera-core-mamehome: what MAME's frontend normally supplies as emulator_info
// (src/frontend/mame/mame.cpp). This core has no frontend: no UI to draw, no
// chooser, no Lua hooks - so every hook does nothing and says so.
#include "emu.h"
#include "main.h"
#include "rendlay.h"

const char *emulator_info::get_appname() { return "MAME"; }
const char *emulator_info::get_appname_lower() { return "mame"; }
const char *emulator_info::get_configname() { return "mame"; }
const char *emulator_info::get_copyright() { return "Copyright MAMEdev and contributors"; }
const char *emulator_info::get_copyright_info() { return "MAME is licensed under the GNU General Public License, version 2 or later"; }
const char *emulator_info::get_bare_build_version() { return "chimera-core-mamehome"; }
const char *emulator_info::get_build_version() { return "chimera-core-mamehome"; }
void emulator_info::display_ui_chooser(running_machine &machine) { }
int emulator_info::start_frontend(emu_options &options, osd_interface &osd, std::vector<std::string> &args) { return 0; }
int emulator_info::start_frontend(emu_options &options, osd_interface &osd, int argc, char *argv[]) { return 0; }
bool emulator_info::draw_user_interface(running_machine &machine) { return false; }
void emulator_info::periodic_check() { }
bool emulator_info::frame_hook() { return false; }
void emulator_info::sound_hook(const std::map<std::string, std::vector<std::pair<const float *, int>>> &sound) { }
void emulator_info::layout_script_cb(layout_file &file, const char *script) { }
bool emulator_info::standalone() { return false; }
