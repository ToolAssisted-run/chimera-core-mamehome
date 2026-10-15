// chimera-core-mamehome: home systems of upstream MAME as a Chimera core -
// the Atari 7800, the Intellivision, the Vectrex, the Odyssey 2, the Channel F
// and the Amstrad CPC.
//
// MAME is built the way it builds a chosen set of machines (build-mame.sh),
// and this file is the rest of what an emulator needs around it: MAME's
// frontend and its OSD layer are replaced by
//
//  * a machine_manager whose UI does nothing - no menus, no startup text, no
//    warning screens, no Lua, no plugins;
//  * an osd_interface that hands each frame's picture (MAME's own software
//    renderer) and each frame's sound (one stereo stream) to the sandbox;
//  * each machine's own controls, written straight into the fields of its
//    ports each frame - no input devices, no key bindings, no smoothing of
//    an analog control;
//  * the game's files put into the machine's cartridge slot, disk drives or
//    tape by their extensions, and MAME's own audit of the machine's
//    firmware before the machine is built.
//
// MAME runs its machine as a loop that returns only when the machine exits.
// That loop runs on a cothread of its own, and the OSD's per-frame update()
// - which MAME calls at every VBLANK of the screen - switches back to the
// caller of mame_frame(): a frame is exactly one turn of MAME's own loop, and
// nothing in it is reordered.

#include "emu.h"
#include "emuopts.h"
#include "input.h"
#include "inputdev.h"
#include "frontend/mame/ui/menuitem.h"
#include "frontend/mame/audit.h"
#include "main.h"
#include "render.h"
#include "rendersw.hxx"
#include "drivenum.h"
#include "romload.h"
#include "fileio.h"
#include "path.h"
#include "screen.h"
#include "dinvram.h"
#include "ioprocs.h"
#include "ioprocsvec.h"
#include "sound.h"
#include "video.h"
#include "ui/uimain.h"
#include "osdepend.h"
#include "inpttype.ipp"
#include "modules/lib/osdobj_common.h"

#include "libco/libco.h"
#include "mame-driver.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int kSampleRate = 48000;
constexpr int kMaxSide = 2048;     // waterbox.config, video

std::string s_game;
std::map<std::string, std::string> s_options;
std::map<std::string, std::string> s_switches;
// the game's files, in order: each goes into one of the machine's media devices
std::vector<std::string> s_media;
std::string s_error;
std::string s_log;          // what MAME printed as errors and warnings
running_machine *s_machine;

// why the machine may not start, found while MAME was starting it. MAME
// catches what is thrown there and carries on, so it is kept and mame_init
// answers with it.
std::string s_refused;

// ---- the panel -----------------------------------------------------------
// A machine's controls are its own: every input field of its ports that is a
// control, named as below, in a fixed order. The package declares the same
// list for each machine - gen-config.py writes it from `run-native --walk`,
// which runs this same code - so a control's index is its place in the list.
//
// A control's name:
//  - a field of a player's kind (a joystick direction, a button) is MAME's
//    name for the kind and the player, "P1 Up", "P2 Button 1", or "P1 " and
//    the driver's own name for it when it has one ("P1 Push Down");
//  - any other field (a console switch, a keypad key, a keyboard key) is the
//    driver's name for it: "Reset", "Enter", "A";
//  - when two devices would give one name (the Intellivision's two hand
//    controllers are one device twice), every control of those devices is
//    "P<n> " and its name, n counting the devices in the order of their tags.
// Two fields of one machine with one name are one control, as they are one
// key in MAME. The order: each player's controls (MAME's order of kinds, then
// the driver's own order), then the controls of no player.
struct control
{
	std::string name;
	std::string label;      // unused: a home machine's names are the driver's own
	ioport_type type = IPT_INVALID;
	bool analog = false;
	std::vector<ioport_field *> fields;
	// an axis: its rest and its two ends as the machine reads them (a control
	// whose range is signed has a negative end), and the bits of its field
	s32 rest = 0, min = 0, max = 0;
	u32 bits = 0;
	bool relative = false;  // a dial, a ball or a mouse: the axis is this frame's movement
	s32 position = 0;       // where a relative control has got to
	s32 written = 0;        // what the machine was last given
	// the order
	int player = 0;         // 1 and up, or 0 for none
	int group = 0;          // 0 a kind of MAME's, 1 a field of no kind
	int order = 0;          // MAME's place for the kind, or the driver's order
};
std::vector<control> s_buttons, s_axes;
std::vector<int32_t> s_button_state, s_axis_state;
bool s_input_read;
// the ports that hold at least one control: a read of one of these is the
// machine looking at its controls (a port of switches is not)
std::set<ioport_port *> s_control_ports;
// a machine that is TOLD when a control changes (a callback on the field)
// never reads a port for it, and has no frame that did not read its controls
bool s_controls_pushed;

// a control with no kind of its own
bool is_nameless(ioport_type type)
{
	return type == IPT_OTHER || type == IPT_KEYPAD || type == IPT_KEYBOARD;
}

// MAME's list of kinds of control, as its input manager makes it: the same
// for every machine, and needing no running machine
std::vector<input_type_entry> const &type_list()
{
	static std::vector<input_type_entry> const list = [] {
		std::vector<input_type_entry> l;
		emplace_core_types(l);
		return l;
	}();
	return list;
}

int type_index(ioport_type type, int player)
{
	auto const &list = type_list();
	for (size_t i = 0; i < list.size(); i++)
		if (list[i].type() == type && list[i].player() == player) return int(i);
	return -1;
}

// "P1 " at the front of a name, as MAME writes a player
std::string without_player(std::string name)
{
	if (name.size() > 3 && name[0] == 'P' && std::isdigit(u8(name[1])))
	{
		size_t at = 1;
		while (at < name.size() && std::isdigit(u8(name[at]))) at++;
		if (at < name.size() && name[at] == ' ') name.erase(0, at + 1);
	}
	return name;
}

// A control's name in plain ASCII: a movie and a key binding name controls,
// and some keyboards' keys are named by their symbols ("\xe2\x86\x91" for the
// CPC's cursor key). Each symbol a key of this build has is spelled out;
// any other is "?", which the test script refuses.
std::string ascii_name(std::string name)
{
	static std::pair<const char *, const char *> const spelled[] = {
		{ "\xe2\x86\x91", "Cursor Up" }, { "\xe2\x86\x93", "Cursor Down" },
		{ "\xe2\x86\x90", "Cursor Left" }, { "\xe2\x86\x92", "Cursor Right" },
		{ "\xe2\x86\x96", "Home" }, { "\xc2\xa3", "Pound" }, { "\xc3\x97", "Times" },
		{ "\xc3\xb7", "Divide" }, { "\xc2\xa8", "Diaeresis" }, { "\xd0\xaa", "Hard Sign" },
	};
	for (auto const &sp : spelled)
		for (size_t at; (at = name.find(sp.first)) != std::string::npos;)
			name.replace(at, std::strlen(sp.first), sp.second);
	std::string out;
	for (size_t i = 0; i < name.size(); i++)
	{
		unsigned char const ch = name[i];
		if (ch < 0x80) { out += char(ch); continue; }
		out += '?';
		while (i + 1 < name.size() && (u8(name[i + 1]) & 0xc0) == 0x80) i++;
	}
	// one space between words
	std::string tidy;
	for (char ch : out)
		if (ch != ' ' || (!tidy.empty() && tidy.back() != ' ')) tidy += ch;
	while (!tidy.empty() && tidy.back() == ' ') tidy.pop_back();
	return tidy;
}

// the lowest set bit of a field's mask: where its value starts in the port
int field_shift(ioport_field const &field)
{
	int shift = 0;
	for (ioport_value mask = field.mask(); mask && !(mask & 1); mask >>= 1) shift++;
	return shift;
}

// An analog field as the frontend drives it: where it rests, how far it goes
// each way, and whether the axis is a position or a movement. MAME's own
// reading of the same field is analog_field's constructor (ioport.cpp).
struct analog_shape { s32 rest, min, max; u32 bits; bool relative; };
analog_shape shape_of(ioport_field const &field)
{
	int const shift = field_shift(field);
	analog_shape a;
	a.bits = u32(field.mask() >> shift);
	a.rest = s32((field.defvalue() & field.mask()) >> shift);
	a.min = s32((field.minval() & field.mask()) >> shift);
	a.max = s32((field.maxval() & field.mask()) >> shift);
	a.relative = field.type() == IPT_DIAL || field.type() == IPT_DIAL_V
		|| field.type() == IPT_TRACKBALL_X || field.type() == IPT_TRACKBALL_Y
		|| field.type() == IPT_MOUSE_X || field.type() == IPT_MOUSE_Y;
	if (a.relative)
	{
		// a counter the width of the field, going round
		a.min = 0;
		a.max = s32(a.bits);
	}
	else if (field.type() == IPT_POSITIONAL || field.type() == IPT_POSITIONAL_V)
	{
		// one of maxval positions
		a.min = 0;
		a.max = std::max<s32>(s32(field.maxval()) - 1, 0);
	}
	else if (a.min > a.max)
	{
		// written as signed: 0x80 to 0x7f is -128 to 127
		a.min -= s32(a.bits) + 1;
		if (a.rest > a.max) a.rest -= s32(a.bits) + 1;
	}
	return a;
}

// The machine's controls, from its ports: a running machine's, or those of a
// machine's description (the walk). Buttons and axes, each in order.
void controls_of(ioport_list const &ports, std::vector<control> &buttons, std::vector<control> &axes)
{
	struct found { ioport_field *field; std::string device, base; int player, group, order; };
	std::vector<found> fields;
	int sequence = 0;
	for (auto &port : ports)
	{
		for (ioport_field &field : port.second->fields())
		{
			ioport_type const type = field.type();
			if (type == IPT_UNUSED || type == IPT_UNKNOWN || type == IPT_SPECIAL || type == IPT_CUSTOM
				|| type == IPT_OUTPUT || type == IPT_DIPSWITCH || type == IPT_CONFIG || type == IPT_ADJUSTER)
				continue;
			found f;
			f.field = &field;
			f.device = port.second->device().tag();
			if (is_nameless(type))
			{
				if (!field.specific_name()) continue;
				f.base = ascii_name(field.specific_name());
				f.player = 0;
				f.group = 1;
				f.order = sequence++;
			}
			else
			{
				int const at = type_index(type, field.player());
				if (at < 0) continue;
				input_type_entry const &entry = type_list()[at];
				if (entry.group() == IPG_UI || entry.group() == IPG_INVALID) continue;
				bool const of_player = entry.group() >= IPG_PLAYER1 && entry.group() <= IPG_PLAYER10;
				f.base = ascii_name(without_player(field.specific_name() ? field.specific_name() : entry.name()));
				f.player = of_player ? field.player() + 1 : 0;
				// MAME names a later player's analog kinds with the player at the
				// end as well: "P2 AD Stick X 2"
				std::string const tail = " " + std::to_string(f.player);
				if (field.is_analog() && f.player > 1 && f.base.size() > tail.size() && f.base.compare(f.base.size() - tail.size(), tail.size(), tail) == 0)
					f.base.erase(f.base.size() - tail.size());
				f.group = 0;
				f.order = at;
			}
			fields.push_back(std::move(f));
		}
	}
	auto const name_of = [] (found const &f) { return f.player ? "P" + std::to_string(f.player) + " " + f.base : f.base; };

	// one name from two devices: those devices' controls take a player each
	std::map<std::string, std::set<std::string>> devices_of;
	for (found const &f : fields) devices_of[name_of(f)].insert(f.device);
	std::set<std::string> shared;
	for (auto const &kv : devices_of)
		if (kv.second.size() > 1) shared.insert(kv.second.begin(), kv.second.end());
	int next = 1;
	std::map<std::string, int> device_player;
	for (std::string const &device : shared) device_player[device] = next++;   // a std::set: tag order
	for (found &f : fields)
	{
		auto const p = device_player.find(f.device);
		if (p == device_player.end()) continue;
		f.player = p->second;
		// a kind's place follows the player's: P2's Up after P2's
		if (f.group == 0) f.order = type_index(f.field->type(), 0) >= 0 ? type_index(f.field->type(), 0) : f.order;
	}
	std::stable_sort(fields.begin(), fields.end(), [] (found const &a, found const &b) {
		int const pa = a.player ? a.player : 1 << 20, pb = b.player ? b.player : 1 << 20;
		if (pa != pb) return pa < pb;
		if (a.group != b.group) return a.group < b.group;
		return a.order < b.order;
	});

	buttons.clear();
	axes.clear();
	for (found const &f : fields)
	{
		std::string const name = name_of(f);
		bool const analog = f.field->is_analog();
		std::vector<control> &list = analog ? axes : buttons;
		auto c = std::find_if(list.begin(), list.end(), [&name] (control const &x) { return x.name == name; });
		if (c == list.end())
		{
			control n;
			n.name = name;
			n.type = f.field->type();
			n.analog = analog;
			n.player = f.player;
			n.group = f.group;
			n.order = f.order;
			if (analog)
			{
				analog_shape const a = shape_of(*f.field);
				n.rest = a.rest;
				n.min = a.min;
				n.max = a.max;
				n.bits = a.bits;
				n.relative = a.relative;
				n.position = a.rest;
			}
			list.push_back(std::move(n));
			c = list.end() - 1;
		}
		c->fields.push_back(f.field);
	}
}

// Finds the machine's controls and takes them off MAME's own key bindings:
// what a field reads is what mame_set_button and mame_set_axis wrote, and
// nothing else.
void build_panel(running_machine &machine)
{
	controls_of(machine.ioport().ports(), s_buttons, s_axes);
	for (std::vector<control> *list : { &s_buttons, &s_axes })
		for (control &c : *list)
			for (ioport_field *field : c.fields)
			{
				ioport_field::user_settings us;
				field->get_user_settings(us);
				for (auto &seq : us.seq) seq = input_seq();
				field->set_user_settings(us);
				s_control_ports.insert(&field->port());
				if (field->has_dynamic_write()) s_controls_pushed = true;
			}
	s_button_state.assign(s_buttons.size(), 0);
	s_axis_state.assign(s_axes.size(), 0);
}

// An axis is the machine's own: 0 is where it rests, and it goes as far each
// way as the machine's control does (the package declares that range). A
// dial, a ball or a mouse is this frame's movement in the machine's counts.
s32 from_wire(control const &c, s32 v)
{
	return std::clamp(c.rest + v, c.min, c.max);
}

// this frame's controls, into the ports
void apply_panel()
{
	for (size_t i = 0; i < s_buttons.size(); i++)
		for (ioport_field *field : s_buttons[i].fields)
			field->set_value(s_button_state[i] ? 1 : 0);
	for (size_t i = 0; i < s_axes.size(); i++)
	{
		control &c = s_axes[i];
		s32 value;
		if (c.relative)
		{
			// a dial has no ends: its counter goes round
			c.position = s32(u32(c.position + s_axis_state[i]) & c.bits);
			value = c.position;
		}
		else
			value = from_wire(c, s_axis_state[i]);
		c.written = value;
		// the port's bits (a negative value in two's complement)
		for (ioport_field *field : c.fields)
			field->set_value(ioport_value(u32(value) & c.bits));
	}
}

// ---- the game's own switches ---------------------------------------------
// A dip switch or a machine configuration switch, by the driver's name for it
// and for the position.
void apply_switches(running_machine &machine)
{
	std::set<std::string> done;
	for (auto &port : machine.ioport().ports())
	{
		for (ioport_field &field : port.second->fields())
		{
			if (field.type() != IPT_DIPSWITCH && field.type() != IPT_CONFIG) continue;
			if (!field.specific_name()) continue;
			auto const want = s_switches.find(field.specific_name());
			if (want == s_switches.end()) continue;
			for (ioport_setting const &setting : field.settings())
			{
				if (want->second != setting.name()) continue;
				ioport_field::user_settings us;
				field.get_user_settings(us);
				us.value = setting.value();
				field.set_user_settings(us);
				done.insert(want->first);
				break;
			}
		}
	}
	for (auto const &kv : s_switches)
		if (!done.count(kv.first))
			s_refused = "this game has no switch \"" + kv.first + "\" with a position \"" + kv.second + "\"";
}

// ---- what the machine keeps with the power off -----------------------------
// Every device of the machine that keeps something (an EEPROM, a battery-
// backed RAM, a timekeeper chip) is one save data file, in the form MAME
// itself writes to its nvram folder, named by the device: ":eeprom" is
// eeprom.nv. MAME's own nvram files are neither read nor written.
std::map<std::string, std::vector<uint8_t>> s_saves_in;
struct save_file { std::string name; std::vector<uint8_t> bytes; };
std::vector<save_file> s_saves_out;

std::string save_name(device_t const &device)
{
	std::string name = device.tag() + 1;
	std::replace(name.begin(), name.end(), ':', '_');
	return name + ".nv";
}

// puts the files given back into their devices: after MAME has set every
// device to its factory contents, before the machine is reset
void load_saves(running_machine &machine)
{
	std::set<std::string> used;
	std::string have;
	for (device_nvram_interface &nvram : nvram_interface_enumerator(machine.root_device()))
	{
		std::string const name = save_name(nvram.device());
		have += (have.empty() ? "" : ", ") + name;
		auto const given = s_saves_in.find(name);
		if (given == s_saves_in.end()) continue;
		auto file = util::ram_read(given->second.data(), given->second.size());
		if (!file || !nvram.nvram_load(*file))
			s_refused = "the save data " + name + " could not be loaded into this machine";
		used.insert(name);
	}
	for (auto const &given : s_saves_in)
		if (!used.count(given.first))
			s_refused = "the save data " + given.first + " is not one of this machine's ("
				+ (have.empty() ? std::string("it keeps nothing") : "it keeps " + have) + ")";
}

// ---- what one frame leaves behind ---------------------------------------
std::vector<uint32_t> s_video;
int s_width, s_height;
int s_aspect_x = 4, s_aspect_y = 3;
std::vector<int16_t> s_audio;

cothread_t s_host, s_mame;
bool s_stopped;

// "(4:3)" at the end of a view's name
bool view_aspect(const char *name, int &x, int &y)
{
	const char *open = std::strrchr(name, '(');
	int a, b;
	if (!open || std::sscanf(open, "(%d:%d)", &a, &b) != 2 || a <= 0 || b <= 0) return false;
	x = a;
	y = b;
	return true;
}

// ---- the OSD --------------------------------------------------------------
class chimera_osd final : public osd_interface
{
public:
	void init(running_machine &machine) override
	{
		m_machine = &machine;
		m_target = machine.render().target_alloc();
		// A machine with one screen is drawn as that screen's own pixels: its
		// "Pixel Aspect" view. The "Standard" view beside it carries the shape
		// the monitor showed them in. Anything else (several screens, a
		// cabinet layout) is drawn as MAME's first view.
		int pixel = -1;
		for (int v = 0; m_target->view_name(v); v++)
		{
			const char *name = m_target->view_name(v);
			if (pixel < 0 && std::strstr(name, "Pixel Aspect")) pixel = v;
			if (std::strstr(name, "Standard")) view_aspect(name, s_aspect_x, s_aspect_y);
		}
		bool const one_screen = screen_device_enumerator(machine.root_device()).count() == 1;
		m_native = one_screen && pixel >= 0;
		if (m_native)
		{
			m_target->set_view(pixel);
			// the picture is the screen's pixels and nothing else: draw() sizes
			// the target to them every frame, whatever shape the view was made in
			m_target->set_keepaspect(false);
		}
	}

	void update(bool skip_redraw) override
	{
		// this frame's sound, all of it (patch 0003): MAME's own periodic update
		// runs at 50 Hz, not at the screen's rate
		m_machine->sound().chimera_flush();
		if (!skip_redraw) draw();
		// the end of a frame: back to mame_frame's caller
		co_switch(s_host);
	}

	void input_update(bool relative_reset) override { }
	void check_osd_inputs() override { }
	void set_verbose(bool print_verbose) override { }
	void init_debugger() override { }
	void wait_for_debugger(device_t &device, bool firststop) override { }

	bool no_sound() override { return false; }
	bool sound_external_per_channel_volume() override { return false; }
	bool sound_split_streams_per_source() override { return false; }
	uint32_t sound_get_generation() override { return 1; }
	osd::audio_info sound_get_information() override
	{
		osd::audio_info result;
		result.m_generation = 1;
		result.m_default_sink = 1;
		result.m_default_source = 0;
		result.m_nodes.resize(1);
		auto &node = result.m_nodes[0];
		node.m_name = "chimera";
		node.m_display_name = "Chimera";
		node.m_id = 1;
		node.m_rate.m_default_rate = kSampleRate;
		node.m_rate.m_min_rate = kSampleRate;
		node.m_rate.m_max_rate = kSampleRate;
		node.m_sinks = 2;
		node.m_sources = 0;
		node.m_port_names = { "L", "R" };
		node.m_port_positions = { osd::channel_position::FL(), osd::channel_position::FR() };
		if (m_stream)
			result.m_streams.emplace_back(m_stream, 1u);
		return result;
	}
	uint32_t sound_stream_sink_open(uint32_t node, std::string name, uint32_t rate) override { return m_stream = 1; }
	uint32_t sound_stream_source_open(uint32_t node, std::string name, uint32_t rate) override { return 0; }
	void sound_stream_close(uint32_t id) override { if (id == m_stream) m_stream = 0; }
	void sound_stream_sink_update(uint32_t id, const int16_t *buffer, int samples_this_frame) override
	{
		s_audio.insert(s_audio.end(), buffer, buffer + 2 * samples_this_frame);
	}
	void sound_stream_source_update(uint32_t id, int16_t *buffer, int samples_this_frame) override { }
	void sound_stream_set_volumes(uint32_t id, const std::vector<float> &db) override { }
	void sound_begin_update() override { }
	void sound_end_update() override { }

	void customize_input_type_list(std::vector<input_type_entry> &typelist) override { }
	void add_audio_to_recording(const int16_t *buffer, int samples_this_frame) override { }
	std::vector<ui::menu_item> get_slider_list() override { return {}; }
	osd_font::ptr font_alloc() override { return nullptr; }
	bool get_font_families(std::string const &font_path, std::vector<std::pair<std::string, std::string>> &result) override { return false; }
	bool execute_command(const char *command) override { return false; }
	std::unique_ptr<osd::midi_input_port> create_midi_input(std::string_view name) override { return nullptr; }
	std::unique_ptr<osd::midi_output_port> create_midi_output(std::string_view name) override { return nullptr; }
	std::vector<osd::midi_port_info> list_midi_ports() override { return {}; }
	std::unique_ptr<osd::network_device> open_network_device(int id, osd::network_handler &handler) override { return nullptr; }
	std::vector<osd::network_device_info> list_network_devices() override { return {}; }

private:
	void draw()
	{
		s32 w = 0, h = 0;
		m_target->compute_minimum_size(w, h);
		if (w <= 0 || h <= 0) return;
		// the package's picture buffer is kMaxSide square: a layout larger
		// than that is drawn smaller, in the same shape
		while (w > kMaxSide || h > kMaxSide) { w = (w + 1) / 2; h = (h + 1) / 2; }
		m_target->set_bounds(w, h);
		s_video.assign(size_t(w) * h, 0);
		s_width = w;
		s_height = h;
		if (!m_native)
		{
			// a layout is drawn in its own shape
			s_aspect_x = w;
			s_aspect_y = h;
		}
		render_primitive_list &prims = m_target->get_primitives();
		prims.acquire_lock();
		software_renderer<uint32_t, 0, 0, 0, 16, 8, 0>::draw_primitives(prims, s_video.data(), w, h, w);
		prims.release_lock();
	}

	running_machine *m_machine = nullptr;
	render_target *m_target = nullptr;
	bool m_native = false;
	uint32_t m_stream = 0;
};

// ---- the frontend ---------------------------------------------------------
class chimera_manager final : public machine_manager
{
public:
	chimera_manager(emu_options &options, osd_interface &osd) : machine_manager(options, osd) { }
	// a UI that shows nothing: no menus, no startup text, no warning screens
	ui_manager *create_ui(running_machine &machine) override { return m_ui = new ui_manager(machine); }
	// the ports exist now, and no saved settings are read after this (readconfig off)
	void before_load_settings(running_machine &machine) override
	{
		build_panel(machine);
		apply_switches(machine);
		// Unthrottled. The "throttle" option is read by MAME's frontend, not by
		// its emulator core, which otherwise paces the machine to the host's
		// clock - sleeping between frames, and deciding by the host's time.
		machine.video().set_throttled(false);
	}
	// MAME has given every device its factory contents (its own nvram files
	// are off) and set the clocks; the machine is not reset yet, so what is
	// loaded here is what it powers on with
	void ui_initialize(running_machine &machine) override { load_saves(machine); }
	~chimera_manager() override { delete m_ui; }
private:
	ui_manager *m_ui = nullptr;
};

chimera_osd *s_osd;
emu_options *s_emu_options;
chimera_manager *s_manager;

void mame_main()
{
	try
	{
		machine_config config(*s_emu_options->system(), *s_emu_options);
		running_machine machine(config, *s_manager);
		s_manager->set_machine(&machine);
		s_machine = &machine;
		int const result = machine.run(false);
		if (s_error.empty())
			s_error = "the machine stopped (MAME exit code " + std::to_string(result) + ")";
	}
	catch (emu_fatalerror const &e)
	{
		s_error = e.what();
	}
	catch (std::exception const &e)
	{
		s_error = e.what();
	}
	if (!s_log.empty())
		s_error += "\n" + s_log;
	s_machine = nullptr;
	s_stopped = true;
	for (;;) co_switch(s_host);
}

void set(core_options &opts, const char *name, std::string const &value)
{
	if (!opts.get_entry(name))
		throw std::runtime_error(std::string("MAME has no option \"") + name + "\"");
	opts.set_value(name, value, OPTION_PRIORITY_CMDLINE);
}

// the options every machine of this core runs with: nothing may depend on the host
void fixed_options(emu_options &o)
{
	set(o, OPTION_THROTTLE, "0");
	set(o, OPTION_SLEEP, "0");
	set(o, OPTION_SAMPLERATE, std::to_string(kSampleRate));
	set(o, OPTION_RTC_TIME, "20000101000000");
	set(o, OPTION_NVRAM_SAVE, "0");
	set(o, OPTION_READCONFIG, "0");
	set(o, OPTION_WRITECONFIG, "0");
	// where the rom sets are: Chimera mounts a project's files in the
	// sandbox's root ("/ssf2t.zip"); the test harnesses run in a work folder
	set(o, OPTION_MEDIAPATH, "/;.");
	set(o, OPTION_SAMPLEPATH, "/;.");
	// both ways of a stick at once reach the game as they are: what a game
	// does with them is the game's
	set(o, OPTION_JOYSTICK_CONTRADICTORY, "1");
}

// whether a media device takes files with this extension (lower case, no dot)
bool takes_extension(device_image_interface const &image, std::string const &ext)
{
	std::string list = image.file_extensions();
	for (size_t at = 0; at <= list.size();)
	{
		size_t const end = std::min(list.find(',', at), list.size());
		if (list.compare(at, end - at, ext) == 0) return true;
		at = end + 1;
	}
	return false;
}

[[maybe_unused]] std::string json(std::string_view s)
{
	std::string out = "\"";
	for (unsigned char ch : s)
	{
		if (ch == '"' || ch == '\\') { out += '\\'; out += char(ch); }
		else if (ch == '\n') out += "\\n";
		else if (ch == '\t') out += "\\t";
		else if (ch < 0x20) out += util::string_format("\\u%04x", unsigned(ch));
		else out += char(ch);
	}
	return out + "\"";
}

// what MAME says of how well a machine is emulated
std::string status_text(game_driver const &driver, machine_config const &config)
{
	std::vector<std::string> parts;
	if (driver.type.emulation_flags() & device_t::flags::NOT_WORKING) parts.emplace_back("MAME marks this machine as NOT WORKING");
	if (driver.flags & MACHINE_MECHANICAL) parts.emplace_back("the machine has mechanical parts MAME does not show");
	device_t::feature_type unemulated = device_t::feature::NONE, imperfect = device_t::feature::NONE;
	for (device_t &device : device_enumerator(config.root_device()))
	{
		unemulated |= device.type().unemulated_features();
		imperfect |= device.type().imperfect_features();
	}
	struct { device_t::feature_type bit; const char *name; } const names[] = {
		{ device_t::feature::PROTECTION, "protection" }, { device_t::feature::GRAPHICS, "graphics" },
		{ device_t::feature::PALETTE, "colours" }, { device_t::feature::SOUND, "sound" },
		{ device_t::feature::TIMING, "timing" }, { device_t::feature::CONTROLS, "controls" },
	};
	for (auto const &n : names)
	{
		if (unemulated & n.bit) parts.push_back(std::string(n.name) + " not emulated");
		else if (imperfect & n.bit) parts.push_back(std::string(n.name) + " imperfect");
	}
	std::string out;
	for (auto const &p : parts) out += (out.empty() ? "" : "; ") + p;
	return out;
}

} // anonymous namespace

// the hash files MAME reads for a cartridge with no header of its own
// (patch 0007): carried in the core, because a sandbox has no folder for them
#include "hash-files.inc"
const char *chimera_hash_file(const char *sysname)
{
	for (auto const *h = kHashFiles; h->system; h++)
		if (!std::strcmp(h->system, sysname)) return h->text;
	return nullptr;
}

// called by MAME at every read of a port (patch 0005)
void chimera_port_read(ioport_port &port)
{
	if (!s_input_read && s_control_ports.count(&port)) s_input_read = true;
}

// MAME's output (errors, warnings) goes to stderr - it is the core's log - and
// is kept, so a machine that will not start can say why
class chimera_output : public osd_output
{
public:
	void output_callback(osd_output_channel channel, util::format_argument_pack<char> const &args) override
	{
		if (channel == OSD_OUTPUT_CHANNEL_ERROR || channel == OSD_OUTPUT_CHANNEL_WARNING)
		{
			std::string const text = util::string_format(args);
			std::fputs(text.c_str(), stderr);
			if (s_log.size() < 16384) s_log += text;
		}
	}
};

static void push_output()
{
	static chimera_output output;
	static bool pushed;
	if (!pushed) osd_output::push(&output);
	pushed = true;
}

extern "C" int mame_set_game(const char *name)
{
	push_output();
	s_game = name;
	if (driver_list::find(name) >= 0) return 0;
	s_error = "This core has no machine named \"" + s_game + "\". It has:";
	for (size_t at = 0; at < driver_list::total(); at++)
		if (std::strcmp(driver_list::driver(at).name, "___empty"))
			s_error += std::string(at ? " " : "") + driver_list::driver(at).name;
	s_error += ".";
	return 1;
}

extern "C" void mame_set_option(const char *name, const char *value) { s_options[name] = value; }
extern "C" void mame_set_switch(const char *name, const char *value) { s_switches[name] = value; }
extern "C" void mame_add_media(const char *file) { s_media.emplace_back(file); }

// ---- the database --------------------------------------------------------
namespace {

struct needed_file
{
	std::string name;       // the file, as MAME names it
	std::string set;        // the machine or device whose file it is
	bool required;          // has a known good dump, and is not optional
	u32 bios = 0;           // 0: read whatever the BIOS; else the one BIOS that reads it
	std::string bios_name;  // that BIOS's name, or ""
	u32 size = 0;
	std::string sha1, crc;
	std::string problem;    // "", or what is wrong with it
};

// Every file the machine reads, with what MAME's audit found for it - the
// files of every BIOS the machine can start with, each marked with its BIOS.
// chosen is the BIOS it will start with: the one asked for, or MAME's default.
std::vector<needed_file> audit(emu_options &options, game_driver const &driver, machine_config &config, u32 &chosen)
{
	chosen = config.root_device().default_bios();
	auto const bioses = romload::entries(driver.rom).get_system_bioses();
	if (auto const asked = s_options.find("bios"); asked != s_options.end())
		for (romload::system_bios const &choice : bioses)
			if (asked->second == choice.get_name()) chosen = choice.get_value();

	std::vector<needed_file> out;
	driver_enumerator drivers(options, driver);
	drivers.next();
	media_auditor auditor(drivers);
	for (device_t &device : device_enumerator(config.root_device()))
	{
		std::vector<needed_file> files;
		for (rom_entry const *region = rom_first_region(device); region; region = rom_next_region(region))
		{
			if (!ROMREGION_ISROMDATA(region)) continue;
			for (rom_entry const *rom = rom_first_file(region); rom; rom = rom_next_file(rom))
			{
				util::hash_collection const hashes(rom->hashdata());
				// a device's own BIOS is MAME's default for it; the machine's is
				// a setting, so each of its BIOS files is kept with its number
				bool const root = &device == &config.root_device();
				if (!root && ROM_GETBIOSFLAGS(rom) != 0 && ROM_GETBIOSFLAGS(rom) != device.default_bios())
					continue;
				needed_file f;
				f.bios = root ? ROM_GETBIOSFLAGS(rom) : 0;
				for (romload::system_bios const &choice : bioses)
					if (f.bios && choice.get_value() == f.bios) f.bios_name = choice.get_name();
				f.name = rom->name();
				f.required = !hashes.flag(util::hash_collection::FLAG_NO_DUMP) && !ROM_ISOPTIONAL(rom);
				f.set = device.shortname();
				f.size = rom_file_size(rom);
				util::sha1_t sha1;
				if (hashes.sha1(sha1)) f.sha1 = sha1.as_string();
				u32 crc;
				if (hashes.crc(crc)) f.crc = util::string_format("%08x", crc);
				files.push_back(std::move(f));
			}
		}
		if (files.empty()) continue;
		auditor.audit_device(device, AUDIT_VALIDATE_FAST);
		// MAME's audit has one record for each file of the device (the other
		// BIOSes' too), in order - or none at all when it found no file of it
		auto const &records = auditor.records();
		for (needed_file &f : files)
		{
			auto record = records.begin();
			for (; record != records.end(); ++record)
				if (record->name() == f.name && record->type() != media_auditor::media_type::DISK) break;
			if (record == records.end())
			{
				if (f.required) f.problem = "missing";
			}
			else
			{
				switch (record->substatus())
				{
				case media_auditor::audit_substatus::NOT_FOUND: if (f.required) f.problem = "missing"; break;
				case media_auditor::audit_substatus::FOUND_BAD_CHECKSUM: f.problem = "found, but its contents are not the ones MAME expects"; break;
				case media_auditor::audit_substatus::FOUND_WRONG_LENGTH:
					f.problem = util::string_format("found, but it is %d bytes and MAME expects %d", record->actual_length(), record->expected_length());
					break;
				default: break;
				}
			}
			out.push_back(std::move(f));
		}
	}
	return out;
}

// what mame_describe found, for the functions that hand it out in pieces
struct described_switch { std::string name, kind, chosen; std::vector<std::string> options; };
struct described
{
	std::string error, title, status;
	std::vector<needed_file> files;         // with the BIOS the machine starts with
	std::vector<needed_file> every;         // with every BIOS
	std::vector<std::pair<std::string, std::string>> bios;   // name, description
	std::string default_bios;
	std::vector<described_switch> switches;
};
described s_desc;

// the machine's switches, from its description
std::vector<described_switch> switches_of(machine_config &config)
{
	std::vector<described_switch> out;
	ioport_list ports;
	std::ostringstream errors;
	for (device_t &device : device_enumerator(config.root_device()))
		ports.append(device, errors);
	std::set<std::string> seen;
	for (auto &port : ports)
	{
		for (ioport_field const &field : port.second->fields())
		{
			if (field.type() != IPT_DIPSWITCH && field.type() != IPT_CONFIG) continue;
			if (!field.specific_name() || !seen.insert(field.specific_name()).second) continue;
			described_switch sw;
			for (ioport_setting const &setting : field.settings())
			{
				// two positions of one switch with one name are one option
				if (std::find(sw.options.begin(), sw.options.end(), setting.name()) != sw.options.end()) continue;
				sw.options.emplace_back(setting.name());
				if (setting.value() == field.defvalue()) sw.chosen = setting.name();
			}
			if (sw.options.empty()) continue;
			if (sw.chosen.empty()) sw.chosen = sw.options[0];
			sw.name = field.specific_name();
			sw.kind = field.type() == IPT_DIPSWITCH ? "dip" : "config";
			out.push_back(std::move(sw));
		}
	}
	return out;
}

void describe_machine(game_driver const &driver)
{
	emu_options options;
	fixed_options(options);
	options.set_system_name(driver.name);
	machine_config config(driver, options);
	s_desc = described();
	s_desc.title = util::string_format("%s (%s, %s)", driver.type.fullname(), driver.year, driver.manufacturer);
	s_desc.status = status_text(driver, config);
	u32 chosen = 0;
	s_desc.every = audit(options, driver, config, chosen);
	for (needed_file const &f : s_desc.every)
		if (f.bios == 0 || f.bios == chosen) s_desc.files.push_back(f);
	for (romload::system_bios const &bios : romload::entries(driver.rom).get_system_bioses())
	{
		if (bios.get_value() == config.root_device().default_bios()) s_desc.default_bios = bios.get_name();
		s_desc.bios.emplace_back(bios.get_name(), bios.get_description());
	}
	s_desc.switches = switches_of(config);
}

} // anonymous namespace

// Describes the chosen machine and checks its firmware: 0 when it could be
// described (mame_report says what it found), 1 when not.
extern "C" int mame_describe(void)
{
	push_output();
	try
	{
		int const index = driver_list::find(s_game.c_str());
		if (index < 0) throw std::runtime_error(s_error);
		describe_machine(driver_list::driver(index));
		return 0;
	}
	catch (std::exception const &e)
	{
		s_desc = described();
		s_desc.error = e.what();
		return 1;
	}
}

// The description in words: the machine, what MAME says of it, the firmware
// files it reads, and every one of them that is missing or wrong.
extern "C" const char *mame_report(void)
{
	static std::string out;
	if (!s_desc.error.empty()) return (out = s_desc.error).c_str();
	out = s_desc.title + ".";
	if (!s_desc.status.empty()) out += " MAME's notes: " + s_desc.status + ".";
	std::vector<needed_file const *> problems;
	std::string names;
	int required = 0;
	for (needed_file const &f : s_desc.files)
	{
		if (!f.required) continue;
		required++;
		names += (names.empty() ? "" : ", ") + f.name;
		if (!f.problem.empty()) problems.push_back(&f);
	}
	if (!required)
		out += " This machine needs no firmware.";
	else
		out += " It reads " + std::to_string(required) + " firmware file" + (required == 1 ? "" : "s") + ": " + names + ".";
	if (!problems.empty())
	{
		out += " " + std::to_string(problems.size()) + (problems.size() == 1 ? " is" : " are") + " missing or wrong:";
		for (size_t i = 0; i < problems.size(); i++)
			out += std::string(i ? ";" : "") + " " + problems[i]->name + " - " + problems[i]->problem;
		out += ".";
	}
	return out.c_str();
}

extern "C" int mame_problem_count(void)
{
	if (!s_desc.error.empty()) return 1;
	int n = 0;
	for (needed_file const &f : s_desc.files) n += !f.problem.empty();
	return n;
}

// The machine's own settings, by the keys the package declares them under:
// "bios" for a machine with more than one, "dip.<name>" and "config.<name>"
extern "C" int mame_game_setting_count(void) { return int(s_desc.switches.size()) + (s_desc.bios.size() > 1 ? 1 : 0); }
extern "C" const char *mame_game_setting_key(int index)
{
	static std::string out;
	if (s_desc.bios.size() > 1 && index-- == 0) return "bios";
	if (index < 0 || index >= int(s_desc.switches.size())) return "";
	return (out = s_desc.switches[index].kind + "." + s_desc.switches[index].name).c_str();
}

// Gives one of those settings its value, before mame_init. 0 when the
// machine has that setting and that value. A BIOS is named by its
// description, as the setting shows it.
extern "C" int mame_apply_game_setting(const char *key, const char *value)
{
	if (!std::strcmp(key, "bios"))
	{
		for (auto const &bios : s_desc.bios)
			if (bios.second == value || bios.first == value) { s_options["bios"] = bios.first; return 0; }
		return 1;
	}
	for (described_switch const &sw : s_desc.switches)
	{
		if (sw.kind + "." + sw.name != key) continue;
		if (std::find(sw.options.begin(), sw.options.end(), value) == sw.options.end()) return 1;
		s_switches[sw.name] = value;
		return 0;
	}
	return 1;
}

// ---- the walk ----------------------------------------------------------------
// Every machine of this build, described without running it: what the
// package declares for it (gen-config.py reads this). One line a fact:
//   machine <name>\t<full name>\t<year>\t<maker>\t<parent>\t<MAME's notes>
//   bios <name>\t<description>\t<1 for MAME's default>
//   file <name>\t<size>\t<sha1>\t<crc>\t<machine or device>\t<bios or ->\t<1 required>
//   media <option>\t<extensions>\t<1 must be loaded>
//   switch <dip|config>\t<name>\t<default>\t<option>|<option>...
//   button <name>
//   axis <name>\t<low>\t<high>\t<1 a movement>
extern "C" void mame_walk(void)
{
	push_output();
	for (size_t at = 0; at < driver_list::total(); at++)
	{
		game_driver const &driver = driver_list::driver(at);
		if (!std::strcmp(driver.name, "___empty")) continue;
		try
		{
			describe_machine(driver);
			std::printf("machine %s\t%s\t%s\t%s\t%s\t%s\n", driver.name, driver.type.fullname(), driver.year, driver.manufacturer,
				driver_list::find(driver.parent) >= 0 ? driver.parent : "", s_desc.status.c_str());
			for (auto const &bios : s_desc.bios)
				std::printf("bios %s\t%s\t%d\n", bios.first.c_str(), bios.second.c_str(), bios.first == s_desc.default_bios ? 1 : 0);
			for (needed_file const &f : s_desc.every)
				std::printf("file %s\t%u\t%s\t%s\t%s\t%s\t%d\n", f.name.c_str(), f.size, f.sha1.c_str(), f.crc.c_str(), f.set.c_str(),
					f.bios_name.empty() ? "-" : f.bios_name.c_str(), f.required ? 1 : 0);
			emu_options options;
			fixed_options(options);
			options.set_system_name(driver.name);
			machine_config config(driver, options);
			for (device_image_interface &image : image_interface_enumerator(config.root_device()))
				std::printf("media %s\t%s\t%d\n", image.instance_name().c_str(), image.file_extensions(), image.must_be_loaded() ? 1 : 0);
			for (described_switch const &sw : s_desc.switches)
			{
				std::string all;
				for (std::string const &o : sw.options) all += (all.empty() ? "" : "|") + o;
				std::printf("switch %s\t%s\t%s\t%s\n", sw.kind.c_str(), sw.name.c_str(), sw.chosen.c_str(), all.c_str());
			}
			ioport_list ports;
			std::ostringstream errors;
			for (device_t &device : device_enumerator(config.root_device()))
				ports.append(device, errors);
			std::vector<control> buttons, axes;
			controls_of(ports, buttons, axes);
			for (control const &c : buttons) std::printf("button %s\n", c.name.c_str());
			for (control const &c : axes)
				std::printf("axis %s\t%d\t%d\t%d\n", c.name.c_str(), c.relative ? -s32(c.bits) : c.min - c.rest,
					c.relative ? s32(c.bits) : c.max - c.rest, c.relative ? 1 : 0);
		}
		catch (std::exception const &e)
		{
			std::printf("failed %s %s\n", driver.name, e.what());
		}
	}
}

extern "C" int mame_init(void)
{
	push_output();
	s_log.clear();
	try
	{
		s_emu_options = new emu_options();
		auto &o = *s_emu_options;
		fixed_options(o);
		o.set_system_name(s_game);
		for (auto const &kv : s_options)
			set(o, kv.first.c_str(), kv.second);
		if (!o.system())
			throw std::runtime_error("MAME has no machine named \"" + s_game + "\"");
		// the game's files, each into the first of the machine's media devices
		// (a cartridge slot, a disk drive, a tape) that takes its extension and
		// has none yet
		if (!s_media.empty())
		{
			machine_config config(*o.system(), o);
			std::set<std::string> used;
			for (std::string const &file : s_media)
			{
				std::string ext(core_filename_extract_extension(file, true));
				std::transform(ext.begin(), ext.end(), ext.begin(), [] (unsigned char ch) { return char(std::tolower(ch)); });
				std::string takes;
				bool placed = false;
				for (device_image_interface &image : image_interface_enumerator(config.root_device()))
				{
					takes += (takes.empty() ? "" : ", ") + image.instance_name() + " (" + image.file_extensions() + ")";
					if (placed || used.count(image.instance_name()) || !takes_extension(image, ext)) continue;
					set(o, image.instance_name().c_str(), file);
					used.insert(image.instance_name());
					placed = true;
				}
				if (!placed)
					throw std::runtime_error("this machine has no place for " + file + ": it takes " + (takes.empty() ? std::string("no files") : takes));
			}
		}

		s_osd = new chimera_osd();
		s_manager = new chimera_manager(o, *s_osd);
		// what MAME's frontend always does; the machine asks for the server object
		// whether or not it serves anything, and with http off it serves nothing
		s_manager->start_http_server();
	}
	catch (std::exception const &e)
	{
		s_error = e.what();
		return 1;
	}
	s_host = co_active();
	s_mame = co_create(16 * 1024 * 1024, mame_main);
	co_switch(s_mame);
	if (!s_refused.empty())
	{
		s_error = s_refused;
		return 1;
	}
	return s_stopped ? 1 : 0;
}

extern "C" const char *mame_error(void) { return s_error.c_str(); }

extern "C" int mame_frame(void)
{
	if (s_stopped) return 1;
	s_audio.clear();
	s_input_read = false;
	apply_panel();
	co_switch(s_mame);
	return s_stopped ? 1 : 0;
}

extern "C" const uint32_t *mame_video(int *width, int *height)
{
	*width = s_width;
	*height = s_height;
	return s_video.data();
}

extern "C" void mame_aspect(int *x, int *y)
{
	*x = s_aspect_x;
	*y = s_aspect_y;
}

extern "C" const int16_t *mame_audio(int *frames)
{
	*frames = int(s_audio.size() / 2);
	return s_audio.data();
}

extern "C" int mame_sample_rate(void) { return kSampleRate; }

extern "C" int mame_refresh_millihertz(void)
{
	if (!s_machine) return 60000;
	screen_device *const screen = screen_device_enumerator(s_machine->root_device()).first();
	if (!screen) return 60000;
	return int(screen->frame_period().as_hz() * 1000.0 + 0.5);
}

extern "C" int mame_button_count(void) { return int(s_buttons.size()); }
extern "C" const char *mame_button_name(int i) { return i >= 0 && i < int(s_buttons.size()) ? s_buttons[i].name.c_str() : ""; }
extern "C" const char *mame_button_label(int i) { return i >= 0 && i < int(s_buttons.size()) ? s_buttons[i].label.c_str() : ""; }
// A control is live unless every field of it is switched off by the machine's
// configuration (the Intellivision's disc is sixteen buttons or two axes, as
// its Controller Disc Emulation switch says)
static bool live(control const &c)
{
	for (ioport_field const *field : c.fields)
		if (field->enabled()) return true;
	return false;
}
extern "C" int mame_button_active(int i) { return i >= 0 && i < int(s_buttons.size()) && live(s_buttons[i]); }
extern "C" void mame_set_button(int i, int pressed)
{
	if (i >= 0 && i < int(s_button_state.size())) s_button_state[i] = pressed ? 1 : 0;
}

extern "C" int mame_axis_count(void) { return int(s_axes.size()); }
extern "C" const char *mame_axis_name(int i) { return i >= 0 && i < int(s_axes.size()) ? s_axes[i].name.c_str() : ""; }
extern "C" const char *mame_axis_label(int i) { return i >= 0 && i < int(s_axes.size()) ? s_axes[i].label.c_str() : ""; }
extern "C" int mame_axis_active(int i) { return i >= 0 && i < int(s_axes.size()) && live(s_axes[i]); }
extern "C" void mame_axis_range(int i, int *min, int *max)
{
	*min = *max = 0;
	if (i < 0 || i >= int(s_axes.size()) || s_axes[i].fields.empty()) return;
	control const &c = s_axes[i];
	if (c.relative) { *min = -s32(c.bits); *max = s32(c.bits); }
	else { *min = c.min - c.rest; *max = c.max - c.rest; }
}
// The axes this machine has, each on a line, for a test to read: the
// machine's own range and rest, and what the machine is given when the
// frontend's axis is at the low end of the declared range, at rest and at
// its high end.
extern "C" const char *mame_describe_axes(void)
{
	static std::string text;
	text.clear();
	for (size_t i = 0; i < s_axes.size(); i++)
	{
		control const &c = s_axes[i];
		char line[320];
		if (c.relative)
			std::snprintf(line, sizeof line, "axis %zu %s movement\n", i, c.name.c_str());
		else
			std::snprintf(line, sizeof line, "axis %zu %s machine %d %d %d gives %d %d %d\n", i, c.name.c_str(),
				c.min, c.rest, c.max, from_wire(c, c.min - c.rest), from_wire(c, 0), from_wire(c, c.max - c.rest));
		text += line;
	}
	return text.c_str();
}

extern "C" void mame_set_axis(int i, int value)
{
	if (i >= 0 && i < int(s_axis_state.size())) s_axis_state[i] = value;
}

extern "C" int mame_input_was_read(void) { return s_input_read || s_controls_pushed ? 1 : 0; }

// ---- memory ----------------------------------------------------------------
namespace {
struct domain { std::string name; uint8_t *ptr; int64_t size; };
std::vector<domain> s_domains;
running_machine *s_domains_of;

void find_domains()
{
	if (s_domains_of == s_machine) return;
	s_domains.clear();
	s_domains_of = s_machine;
	if (!s_machine) return;
	// the machine's named memory, in name order (MAME keeps it unordered)
	// (":nvram" is nvram: MAME's tags start at the machine, which is ":")
	for (auto const &share : s_machine->memory().shares())
		s_domains.push_back({ share.first.c_str() + (share.first[0] == ':' ? 1 : 0), static_cast<uint8_t *>(share.second->ptr()), int64_t(share.second->bytes()) });
	std::sort(s_domains.begin(), s_domains.end(), [] (domain const &a, domain const &b) { return a.name < b.name; });
	// RAM a processor's memory map declares without naming it (most home
	// machines' work RAM): one domain a range, "maincpu:0100", in the map's
	// order, the processors in MAME's order
	for (device_memory_interface &memory : memory_interface_enumerator(s_machine->root_device()))
	{
		if (!memory.has_space(AS_PROGRAM)) continue;
		address_space &space = memory.space(AS_PROGRAM);
		if (!space.map()) continue;
		for (address_map_entry const &entry : space.map()->m_entrylist)
		{
			if (entry.m_read.m_type != AMH_RAM || entry.m_share || entry.m_addrend < entry.m_addrstart) continue;
			auto *const ptr = static_cast<uint8_t *>(space.get_read_ptr(entry.m_addrstart));
			if (!ptr) continue;
			int64_t const bytes = int64_t(space.address_to_byte(entry.m_addrend)) - int64_t(space.address_to_byte(entry.m_addrstart))
				+ (space.data_width() / 8);
			s_domains.push_back({ util::string_format("%s:%04x", memory.device().tag() + 1, entry.m_addrstart), ptr, bytes });
		}
	}
	// and memory a driver keeps in arrays of its own, reached through its own
	// handlers (the Intellivision's RAM): every array of 64 bytes or more it
	// registers for MAME's savestates, by MAME's name for it, unless it is
	// memory already listed
	auto const covered = [] (uint8_t const *p) {
		for (domain const &d : s_domains)
			if (p >= d.ptr && p < d.ptr + d.size) return true;
		return false;
	};
	save_manager &save = s_machine->save();
	std::vector<domain> items;
	for (int i = 0; i < save.registration_count(); i++)
	{
		void *base;
		u32 valsize, valcount, blockcount, stride;
		const char *name = save.indexed_item(i, base, valsize, valcount, blockcount, stride);
		// (not the sound streams' buffers: they are MAME's, not the machine's)
		if (!name || blockcount != 1 || !std::strncmp(name, "stream.", 7)) continue;
		int64_t const bytes = int64_t(valsize) * valcount;
		if (bytes < 64 || covered(static_cast<uint8_t *>(base))) continue;
		items.push_back({ name, static_cast<uint8_t *>(base), bytes });
	}
	s_domains.insert(s_domains.end(), items.begin(), items.end());
}
}

extern "C" int mame_domain_count(void) { find_domains(); return int(s_domains.size()); }
extern "C" const char *mame_domain_name(int i) { find_domains(); return i >= 0 && i < int(s_domains.size()) ? s_domains[i].name.c_str() : ""; }
extern "C" uint8_t *mame_domain_ptr(int i) { find_domains(); return i >= 0 && i < int(s_domains.size()) ? s_domains[i].ptr : nullptr; }
extern "C" int64_t mame_domain_size(int i) { find_domains(); return i >= 0 && i < int(s_domains.size()) ? s_domains[i].size : 0; }

// ---- save data --------------------------------------------------------------
extern "C" void mame_set_save_file(const char *name, const uint8_t *data, int64_t size)
{
	s_saves_in[name].assign(data, data + size);
}

extern "C" int mame_save_count(void)
{
	s_saves_out.clear();
	if (!s_machine) return 0;
	for (device_nvram_interface &nvram : nvram_interface_enumerator(s_machine->root_device()))
	{
		if (!nvram.nvram_can_save()) continue;
		save_file f;
		f.name = save_name(nvram.device());
		util::vector_read_write_adapter<uint8_t> file(f.bytes);
		if (nvram.nvram_save(file) && !f.bytes.empty())
			s_saves_out.push_back(std::move(f));
	}
	return int(s_saves_out.size());
}
extern "C" const char *mame_save_name(int i) { return i >= 0 && i < int(s_saves_out.size()) ? s_saves_out[i].name.c_str() : ""; }
extern "C" int64_t mame_save_size(int i) { return i >= 0 && i < int(s_saves_out.size()) ? int64_t(s_saves_out[i].bytes.size()) : 0; }
extern "C" const uint8_t *mame_save_data(int i) { return i >= 0 && i < int(s_saves_out.size()) ? s_saves_out[i].bytes.data() : nullptr; }

// ---- the address spaces ----------------------------------------------------
// Each processor's program space is a bus: memory at the addresses the game
// itself uses, in the processor's byte order. A read goes through MAME's own
// handlers with their side effects off, so reading a register changes
// nothing. The ranges are the map's RAM (what a RAM search is for); a space
// whose addresses are not bytes (a few signal processors') is left out.
namespace {
struct bus { std::string name; address_space *space; int64_t size; std::vector<int64_t> ranges; };
std::vector<bus> s_buses;
running_machine *s_buses_of;

void find_buses()
{
	if (s_buses_of == s_machine) return;
	s_buses.clear();
	s_buses_of = s_machine;
	if (!s_machine) return;
	for (device_memory_interface &memory : memory_interface_enumerator(s_machine->root_device()))
	{
		if (!memory.has_space(AS_PROGRAM)) continue;
		address_space &space = memory.space(AS_PROGRAM);
		if (space.addr_shift() != 0) continue;
		bus b;
		b.name = memory.device().tag() + 1;      // ":maincpu" is maincpu
		b.space = &space;
		b.size = int64_t(space.addrmask()) + 1;
		if (space.map())
			for (address_map_entry const &entry : space.map()->m_entrylist)
				if (entry.m_read.m_type == AMH_RAM && entry.m_write.m_type != AMH_NONE && entry.m_addrend >= entry.m_addrstart)
				{
					b.ranges.push_back(entry.m_addrstart);
					b.ranges.push_back(int64_t(entry.m_addrend) - entry.m_addrstart + 1);
				}
		b.ranges.push_back(0);
		b.ranges.push_back(0);
		// the main processor first, the others in MAME's order
		if (b.name == "maincpu") s_buses.insert(s_buses.begin(), std::move(b));
		else s_buses.push_back(std::move(b));
	}
}
}

extern "C" int mame_bus_count(void) { find_buses(); return int(s_buses.size()); }
extern "C" const char *mame_bus_name(int i) { find_buses(); return i >= 0 && i < int(s_buses.size()) ? s_buses[i].name.c_str() : ""; }
extern "C" int64_t mame_bus_size(int i) { find_buses(); return i >= 0 && i < int(s_buses.size()) ? s_buses[i].size : 0; }
extern "C" const int64_t *mame_bus_ranges(int i) { find_buses(); return i >= 0 && i < int(s_buses.size()) ? s_buses[i].ranges.data() : nullptr; }
extern "C" void mame_bus_read(int i, int64_t address, uint8_t *out, int length)
{
	find_buses();
	std::memset(out, 0, length);
	if (i < 0 || i >= int(s_buses.size())) return;
	auto const quiet = s_machine->disable_side_effects();
	address_space &space = *s_buses[i].space;
	for (int n = 0; n < length; n++)
		out[n] = space.read_byte(offs_t(address + n) & space.addrmask());
}
extern "C" void mame_bus_write(int i, int64_t address, int value)
{
	find_buses();
	if (i < 0 || i >= int(s_buses.size())) return;
	address_space &space = *s_buses[i].space;
	space.write_byte(offs_t(address) & space.addrmask(), u8(value));
}

extern "C" const char *mame_list_switches(void)
{
	static std::string out;
	out.clear();
	if (!s_machine) return "";
	for (auto &port : s_machine->ioport().ports())
	{
		for (ioport_field &field : port.second->fields())
		{
			if (field.type() != IPT_DIPSWITCH && field.type() != IPT_CONFIG) continue;
			if (!field.specific_name()) continue;
			ioport_field::user_settings us;
			field.get_user_settings(us);
			std::string now, all;
			for (ioport_setting const &setting : field.settings())
			{
				if (setting.value() == us.value) now = setting.name();
				all += (all.empty() ? "" : " | ") + std::string(setting.name());
			}
			out += std::string(field.specific_name()) + "\t" + now + "\t(" + all + ")\n";
		}
	}
	return out.c_str();
}
