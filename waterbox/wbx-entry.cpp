/* wbx-entry.cpp - the chimera guest ABI over mame-driver.
 *
 * Compiles identically for the guest (miniBox emulibc) and for the native
 * reference build (native-shim/emulibc.h), which is what makes the
 * comparison of the two a real proof: the same driver, the same exports, one
 * in the sandbox and one out of it.
 * SPDX-License-Identifier: MIT
 */
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "mame-driver.h"

static char g_loadError[4096];
static std::string g_suggestion;

static std::string JsonString(const std::string &s)
{
	std::string out = "\"";
	for (unsigned char ch : s)
	{
		if (ch == '"' || ch == '\\') { out += '\\'; out += char(ch); }
		else if (ch == '\n') out += "\\n";
		else if (ch < 0x20) out += ' ';
		else out += char(ch);
	}
	return out + "\"";
}

/* The game's files, as the engine mounted them: the Game slot's, in its
 * order. A file opened with no project has no slot map: it is mounted under
 * its own name, and rom.name says which. */
static std::vector<std::string> GameFiles()
{
	std::vector<std::string> files;
	char entry[512];
	const int32_t n = wbx_slot_count("game");
	for (int32_t i = 0; i < n; i++)
		if (wbx_slot_name("game", i, entry, sizeof entry) != nullptr)
			files.emplace_back(entry);
	if (files.empty())
	{
		FILE *f = fopen("rom.name", "rb");
		if (f)
		{
			size_t got = fread(entry, 1, sizeof entry - 1, f);
			fclose(f);
			entry[got] = '\0';
			files.emplace_back(entry);
		}
	}
	return files;
}

/* Chooses the machine (the Machine setting), hands MAME the game's files and
 * checks the machine's firmware. False, with the reason, when there is no
 * machine to describe. */
static bool Describe(std::string &why)
{
	char machine[64];
	if (wbx_setting_str("machine", machine, sizeof machine) <= 0)
		snprintf(machine, sizeof machine, "%s", "a7800");
	if (mame_set_game(machine) != 0)
	{
		why = mame_error();
		return false;
	}
	for (const std::string &file : GameFiles())
		mame_add_media(file.c_str());
	mame_describe();
	/* the BIOS the project asks for decides which BIOS files are needed */
	char bios[256];
	if (wbx_setting_str("bios", bios, sizeof bios) > 0 && mame_apply_game_setting("bios", bios) == 0)
		mame_describe();
	return true;
}

extern "C" {

ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }

/* Called INSTEAD of Init, on the same files: what MAME says of the machine
 * and of its firmware, for the new-project wizard (engine.h,
 * ce_suggest_settings). */
ECL_EXPORT const char *SuggestSettings(void)
{
	std::string why;
	if (!Describe(why))
		return g_suggestion.assign("{\"values\":{},\"note\":" + JsonString(why) + "}").c_str();
	return g_suggestion.assign("{\"values\":{},\"note\":" + JsonString(mame_report_for_wizard()) + "}").c_str();
}

ECL_EXPORT int Init(void)
{
	g_loadError[0] = '\0';
	std::string why;
	if (!Describe(why))
	{
		snprintf(g_loadError, sizeof g_loadError, "%s", why.c_str());
		return 0;
	}
	/* a firmware file missing or wrong: the machine is not built, and the
	 * reason is MAME's own list */
	if (mame_problem_count() > 0)
	{
		snprintf(g_loadError, sizeof g_loadError, "%s", mame_report());
		return 0;
	}
	/* the machine's own settings: its BIOS and its switches */
	for (int i = 0; i < mame_game_setting_count(); i++)
	{
		const std::string key = mame_game_setting_key(i);
		char val[256];
		if (wbx_setting_str(key.c_str(), val, sizeof val) <= 0) continue;
		if (mame_apply_game_setting(key.c_str(), val) != 0)
		{
			snprintf(g_loadError, sizeof g_loadError, "setting %s: this machine has no value \"%s\"", key.c_str(), val);
			return 0;
		}
	}
	/* what the machine powers on remembering: the Save data slot's files */
	char entry[512];
	const int32_t saves = wbx_slot_count("savedata");
	for (int32_t i = 0; i < saves; i++)
	{
		if (wbx_slot_name("savedata", i, entry, sizeof entry) == nullptr) continue;
		FILE *f = fopen(entry, "rb");
		if (!f)
		{
			snprintf(g_loadError, sizeof g_loadError, "the save data %s could not be read", entry);
			return 0;
		}
		std::vector<uint8_t> bytes;
		uint8_t chunk[65536];
		for (size_t got; (got = fread(chunk, 1, sizeof chunk, f)) > 0;)
			bytes.insert(bytes.end(), chunk, chunk + got);
		fclose(f);
		const char *base = strrchr(entry, '/');
		mame_set_save_file(base ? base + 1 : entry, bytes.data(), int64_t(bytes.size()));
	}
	if (mame_init() != 0)
	{
		snprintf(g_loadError, sizeof g_loadError, "%s", mame_error());
		return 0;
	}
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state) { mame_set_button(index, state); }
ECL_EXPORT int IsButtonActive(int32_t index) { return mame_button_active(index); }
ECL_EXPORT const char *GetButtonName(int32_t index) { return mame_button_name(index); }
ECL_EXPORT int GetButtonCount(void) { return mame_button_count(); }

/* The panel is wider than the packed 64: every control arrives through
 * SetButton (the engine sends a wide panel's changes that way), and the
 * packed mask is not read. */
ECL_EXPORT void FrameAdvance(uint64_t) { mame_frame(); }

ECL_EXPORT int IsAxisActive(int32_t index) { return mame_axis_active(index); }
ECL_EXPORT void SetAxis(int32_t index, int32_t value) { mame_set_axis(index, value); }
ECL_EXPORT int GetAxisCount(void) { return mame_axis_count(); }
ECL_EXPORT const char *GetAxisName(int32_t index) { return mame_axis_name(index); }

ECL_EXPORT int InputWasRead(void) { return mame_input_was_read(); }
ECL_EXPORT void SetRenderingEnabled(int) {}

ECL_EXPORT uint32_t *GetVideoBgra(void)
{
	int w, h;
	return const_cast<uint32_t *>(mame_video(&w, &h));
}
ECL_EXPORT int GetVideoWidth(void)
{
	int w, h;
	mame_video(&w, &h);
	return w;
}
ECL_EXPORT int GetVideoHeight(void)
{
	int w, h;
	mame_video(&w, &h);
	return h;
}
ECL_EXPORT int GetDisplayAspectX(void)
{
	int x, y;
	mame_aspect(&x, &y);
	return x;
}
ECL_EXPORT int GetDisplayAspectY(void)
{
	int x, y;
	mame_aspect(&x, &y);
	return y;
}

ECL_EXPORT int16_t *GetAudio(void)
{
	int n;
	return const_cast<int16_t *>(mame_audio(&n));
}
ECL_EXPORT int GetAudioSampleCount(void)
{
	int n;
	mame_audio(&n);
	return n;
}

ECL_EXPORT int GetVsyncNumerator(void) { return mame_refresh_millihertz(); }
ECL_EXPORT int GetVsyncDenominator(void) { return 1000; }

/* the machine's switches as it has them now, one per line */
ECL_EXPORT const char *DescribeDips(void) { return mame_list_switches(); }
// for the core's own tests: the game's axes and what the declared range gives each
ECL_EXPORT const char *DescribeAxes(void) { return mame_describe_axes(); }

/* The save data: what each device of the machine keeps with the power off,
 * a file each - the form the Save data slot takes back. */
ECL_EXPORT int32_t GetSaveDataFileCount(void) { return mame_save_count(); }
ECL_EXPORT const char *GetSaveDataFileName(int32_t i) { return mame_save_name(i); }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i) { return mame_save_size(i); }
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i) { return mame_save_data(i); }

ECL_EXPORT int GetMemoryDomainCount(void) { return mame_domain_count(); }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return mame_domain_name(i); }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return mame_domain_ptr(i); }
ECL_EXPORT int64_t GetMemoryDomainSize(int i) { return mame_domain_size(i); }
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i >= 0 && i < mame_domain_count(); }

/* Each processor's memory as the game addresses it (mame-driver.h). */
ECL_EXPORT int32_t GetBusCount(void) { return mame_bus_count(); }
ECL_EXPORT const char *GetBusName(int32_t i) { return mame_bus_name(i); }
ECL_EXPORT int64_t GetBusSize(int32_t i) { return mame_bus_size(i); }
ECL_EXPORT int32_t GetBusWritable(int32_t i) { return i >= 0 && i < mame_bus_count(); }
ECL_EXPORT int32_t PeekBus(int32_t bus, int32_t addr)
{
	uint8_t value = 0;
	mame_bus_read(bus, int64_t(uint32_t(addr)), &value, 1);
	return value;
}
ECL_EXPORT void PokeBus(int32_t bus, int32_t addr, int32_t value) { mame_bus_write(bus, int64_t(uint32_t(addr)), value); }
ECL_EXPORT const uint8_t *ReadBus(int32_t bus, int64_t addr, int32_t len)
{
	/* an answer to a tool is in no savestate */
	ECL_INVISIBLE static uint8_t buffer[0x10000];
	if (bus < 0 || bus >= mame_bus_count() || len < 0 || len > int32_t(sizeof buffer)) return nullptr;
	mame_bus_read(bus, addr, buffer, len);
	return buffer;
}
ECL_EXPORT const int64_t *GetBusRanges(int32_t bus)
{
	/* copied out: the list a tool reads is in no savestate either */
	ECL_INVISIBLE static int64_t ranges[2 * 256];
	const int64_t *from = mame_bus_ranges(bus);
	if (!from) return nullptr;
	size_t n = 0;
	for (; n + 2 < sizeof ranges / sizeof ranges[0] && from[n + 1] != 0; n += 2)
	{
		ranges[n] = from[n];
		ranges[n + 1] = from[n + 1];
	}
	ranges[n] = ranges[n + 1] = 0;
	return ranges;
}

/* every machine described, for the script that writes the package (run-native --walk) */
ECL_EXPORT void DebugWalkMachines(void) { mame_walk(); }

} /* extern "C" */
