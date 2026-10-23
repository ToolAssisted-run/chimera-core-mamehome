// chimera-core-mamehome: home systems of upstream MAME as a Chimera core.
// The driver's C interface - what wbx-entry.cpp exports to the sandbox and
// what the native harness calls directly.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The machine, by MAME's short name ("ssf2t"), before mame_init. Returns 0
// when MAME has such a machine; otherwise mame_error() names the closest.
int mame_set_game(const char *name);
// A MAME option by its own name (bios, ...), before mame_init.
void mame_set_option(const char *name, const char *value);
// One of the game's own switches, before mame_init: a dip switch or a machine
// configuration switch by the name the driver gives it, and the name of the
// position to put it in.
void mame_set_switch(const char *name, const char *value);

// A file of the game, before mame_init: it goes into the first of the
// machine's media devices that takes its extension.
void mame_add_media(const char *file);

// Describes the chosen machine and checks its firmware files (looked for in
// the current directory): 0 when it could be described.
int mame_describe(void);
// After mame_describe: the description in words (the machine, MAME's notes
// on it, its firmware files and which are missing or wrong); how many are
// missing or wrong; the machine's own settings (keys "bios", "dip.<name>",
// "config.<name>") and a way to give one a value before mame_init (0 when the
// machine has that setting and that value).
const char *mame_report(void);
// The same for the New Project window, which has given the core no firmware
// yet: a missing file is not said to be, as its Firmware page asks for them.
const char *mame_report_for_wizard(void);
int mame_problem_count(void);
int mame_game_setting_count(void);
const char *mame_game_setting_key(int index);
int mame_apply_game_setting(const char *key, const char *value);

// Builds and starts the machine and runs it to the end of its first frame.
// 0 on success; otherwise mame_error() says why.
int mame_init(void);
const char *mame_error(void);

// One frame. 0 on success; nonzero once the machine has stopped.
int mame_frame(void);

// The picture of the last frame, 0x00RRGGBB, width x height, and the shape
// the cabinet's monitor showed it in.
const uint32_t *mame_video(int *width, int *height);
void mame_aspect(int *x, int *y);
// The sound of the last frame: interleaved stereo, *frames sample pairs.
const int16_t *mame_audio(int *frames);
int mame_sample_rate(void);
// The screen's refresh now, in thousandths of a hertz.
int mame_refresh_millihertz(void);

// The machine's controls, in the order the package declares them for it
// (mame-driver.cpp says how they are named); mame_button_active is 0 for one
// the machine's configuration has switched off.
int mame_button_count(void);
const char *mame_button_name(int index);
int mame_button_active(int index);
void mame_set_button(int index, int pressed);
int mame_axis_count(void);
const char *mame_axis_name(int index);
int mame_axis_active(int index);
// what the axis may be given: the control's own range around its rest at 0
void mame_axis_range(int index, int *min, int *max);
// the machine's axes and what each end of the declared range gives it (a test reads this)
const char *mame_describe_axes(void);
void mame_set_axis(int index, int value);
// The game's own name for a control it has ("Weak Punch"), or "".
const char *mame_button_label(int index);
const char *mame_axis_label(int index);

// Whether the game read a control since the last mame_frame.
int mame_input_was_read(void);

// The machine's memory, for digests and the memory domains.
int mame_domain_count(void);
const char *mame_domain_name(int index);
uint8_t *mame_domain_ptr(int index);
int64_t mame_domain_size(int index);

// What the machine keeps with the power off (EEPROMs, battery-backed RAM),
// one file a device, named by the device ("eeprom.nv"). mame_set_save_file,
// before mame_init, gives a file back to its device; mame_save_count takes
// the files as they are now, and the three after it read that list.
void mame_set_save_file(const char *name, const uint8_t *data, int64_t size);
int mame_save_count(void);
const char *mame_save_name(int index);
int64_t mame_save_size(int index);
const uint8_t *mame_save_data(int index);

// Each processor's address space, as the game addresses it: its name
// ("maincpu"), its size in bytes, the (address, length) pairs of its RAM
// ended by a pair of zeroes, and reads and writes by address.
int mame_bus_count(void);
const char *mame_bus_name(int index);
int64_t mame_bus_size(int index);
const int64_t *mame_bus_ranges(int index);
void mame_bus_read(int index, int64_t address, uint8_t *out, int length);
void mame_bus_write(int index, int64_t address, int value);

// The game's switches as the running machine has them, one per line:
// "name\tvalue\t(options...)".
const char *mame_list_switches(void);

// Describes every machine of this build, without running any, for the
// script that writes the package (see mame-driver.cpp).
void mame_walk(void);

#ifdef __cplusplus
}
#endif
