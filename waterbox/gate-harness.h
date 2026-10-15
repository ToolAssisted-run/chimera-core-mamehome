/* gate-harness.h - the run both harnesses share: run-native (the exports
 * compiled for the host) and run-wbx (core.wbx in the sandbox) parse the same
 * options, press the same controls on the same frames and print the same
 * digests, so their outputs diff directly. A difference between the flavors
 * is then the sandbox's doing, never the harness's.
 *
 * options: --frames N          run length (default 60)
 *          --report N          a digest line every N frames, and the last
 *          --press I:FIRST:N   hold panel control I for N frames from FIRST
 *          --axis I:V:FIRST:N  hold analog axis I at V for N frames from FIRST
 *          --exercise          a deterministic wander over the active
 *                              player controls (never Reset/Test/Service)
 *          --list-panel        print the panel, and which controls are live
 *          --list-dips         print the game's dip switches and their values
 *          --list-axes         print the game's axes: the declared range, the
 *                              machine's own, and what its ends give the machine
 *          --dump-domain NAME FILE   write a memory domain after the run
 *          --dump-domains DIR  every memory domain after the run, a file each
 *                              (its name with / and : as _), and a list, DIR/domains
 *          --vid-out FILE      the last picture: "W H\n" then BGRA rows
 *          --savedata-out DIR  the game's save data after the run, a file each
 * SPDX-License-Identifier: MIT
 */
#ifndef GATE_HARNESS_H
#define GATE_HARNESS_H

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct gate_core
{
	int (*init)(void);
	const char *(*load_error)(void);
	void (*set_button)(int32_t index, int32_t state);
	int (*button_count)(void);
	int (*button_active)(int32_t index);
	const char *(*button_name)(int32_t index);
	const char *(*describe)(void);   /* the game's dip switches, one per line */
	const char *(*describe_axes)(void); /* the game's axes, one per line, or NULL */
	void (*frame)(void);
	int (*input_was_read)(void);
	int (*axis_count)(void);
	int (*axis_active)(int32_t index);
	void (*set_axis)(int32_t index, int32_t value);
	const uint32_t *(*video)(int *w, int *h);
	const int16_t *(*audio)(int *n);
	int (*domain_count)(void);
	const char *(*domain_name)(int i);
	const uint8_t *(*domain_ptr)(int i);
	int64_t (*domain_size)(int i);
	void (*pre_frame)(void); /* run-wbx's rerecord / session hook, or NULL */
	int (*save_count)(void);
	const char *(*save_name)(int i);
	int64_t (*save_size)(int i);
	const uint8_t *(*save_data)(int i);
};

#define GATE_MAX_PRESS 32
struct gate_opts
{
	long frames;
	long report;
	int presses;
	struct { int index; long first, count; } press[GATE_MAX_PRESS];
	int axes;
	struct { int index, value; long first, count; } axis[GATE_MAX_PRESS];
	int exercise;
	int listPanel;
	int listDips;
	int listAxes;
	const char *dumpDomain, *dumpPath, *dumpDomains;
	const char *vidOut;
	const char *savedataOut;
};

static uint64_t gate_fnv(uint64_t h, const void *p, size_t n)
{
	const uint8_t *b = (const uint8_t *)p;
	if (!h) h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
	return h;
}

static int gate_parse_opts(int argc, char **argv, int first, struct gate_opts *o)
{
	memset(o, 0, sizeof *o);
	o->frames = 60;
	o->report = 10;
	for (int i = first; i < argc; i++)
	{
		if (!strcmp(argv[i], "--frames") && i + 1 < argc) o->frames = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--report") && i + 1 < argc) o->report = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--press") && i + 1 < argc && o->presses < GATE_MAX_PRESS)
		{
			int idx; long f, c;
			if (sscanf(argv[++i], "%d:%ld:%ld", &idx, &f, &c) != 3)
			{
				fprintf(stderr, "--press wants INDEX:FIRST:COUNT\n");
				return 0;
			}
			o->press[o->presses].index = idx;
			o->press[o->presses].first = f;
			o->press[o->presses].count = c;
			o->presses++;
		}
		else if (!strcmp(argv[i], "--axis") && i + 1 < argc && o->axes < GATE_MAX_PRESS)
		{
			int idx, val; long f, c;
			if (sscanf(argv[++i], "%d:%d:%ld:%ld", &idx, &val, &f, &c) != 4)
			{
				fprintf(stderr, "--axis wants INDEX:VALUE:FIRST:COUNT\n");
				return 0;
			}
			o->axis[o->axes].index = idx;
			o->axis[o->axes].value = val;
			o->axis[o->axes].first = f;
			o->axis[o->axes].count = c;
			o->axes++;
		}
		else if (!strcmp(argv[i], "--exercise")) o->exercise = 1;
		else if (!strcmp(argv[i], "--list-panel")) o->listPanel = 1;
		else if (!strcmp(argv[i], "--list-dips")) o->listDips = 1;
		else if (!strcmp(argv[i], "--list-axes")) o->listAxes = 1;
		else if (!strcmp(argv[i], "--dump-domain") && i + 2 < argc) { o->dumpDomain = argv[++i]; o->dumpPath = argv[++i]; }
		else if (!strcmp(argv[i], "--dump-domains") && i + 1 < argc) o->dumpDomains = argv[++i];
		else if (!strcmp(argv[i], "--vid-out") && i + 1 < argc) o->vidOut = argv[++i];
		else if (!strcmp(argv[i], "--savedata-out") && i + 1 < argc) o->savedataOut = argv[++i];
		else if (!strcmp(argv[i], "--rerecord") || !strcmp(argv[i], "--session")) ; /* run-wbx's */
		else
		{
			fprintf(stderr, "unknown option %s\n", argv[i]);
			return 0;
		}
	}
	if (o->report <= 0) o->report = o->frames;
	return 1;
}

/* The widest panel the harness drives (MAME knows about a thousand controls). */
#define GATE_MAX_BUTTONS 4096

/* The exercise: an LCG picks, every 6 frames, one live control and holds it
 * for 3. A console's own buttons (Start, Select, Reset) and a computer's
 * keys are among them, so a run that exercises long enough also starts a
 * game. */
static void gate_exercise(const struct gate_core *c, long frame, uint8_t *held)
{
	static uint32_t seed = 12345;
	const int count = c->button_count();
	if (frame % 6 == 0)
	{
		memset(held, 0, GATE_MAX_BUTTONS);
		seed = seed * 1103515245u + 12345u;
		for (int tries = 0; tries < count; tries++)
		{
			const int i = (int)((seed >> 8) % (uint32_t)count);
			seed = seed * 1103515245u + 12345u;
			if (c->button_active(i)) { held[i] = 1; break; }
		}
	}
	else if (frame % 6 == 3)
		memset(held, 0, GATE_MAX_BUTTONS);
}

static uint64_t gate_ram_hash(const struct gate_core *c)
{
	uint64_t h = 0;
	for (int i = 0; i < c->domain_count(); i++)
		h = gate_fnv(h, c->domain_ptr(i), (size_t)c->domain_size(i));
	return h;
}

static int gate_run(const struct gate_core *c, const struct gate_opts *o)
{
	if (c->init() != 1)
	{
		fprintf(stderr, "Init failed: %s\n", c->load_error());
		return 1;
	}
	const int count = c->button_count();
	if (o->listPanel)
	{
		for (int i = 0; i < count; i++)
			printf("panel %d '%s' %s\n", i, c->button_name(i), c->button_active(i) ? "active" : "-");
		for (int a = 0; a < c->axis_count(); a++)
			printf("axis %d %s\n", a, c->axis_active(a) ? "active" : "-");
	}
	if (o->listDips && c->describe)
		fputs(c->describe(), stdout);
	if (o->listAxes && c->describe_axes)
		fputs(c->describe_axes(), stdout);
	uint8_t held[GATE_MAX_BUTTONS] = {0};
	long lag = 0;
	for (long f = 1; f <= o->frames; f++)
	{
		if (c->pre_frame) c->pre_frame();
		if (o->exercise) gate_exercise(c, f, held);
		/* the exercise moves every live axis too: a slow sweep, the same in
		 * both flavors */
		if (o->exercise)
			for (int a = 0; a < c->axis_count(); a++)
				if (c->axis_active(a))
					c->set_axis(a, (int32_t)((f * 37 + a * 311) % 2048) - 1024);
		for (int i = 0; i < count && i < GATE_MAX_BUTTONS; i++)
		{
			int on = held[i];
			for (int p = 0; p < o->presses; p++)
				if (o->press[p].index == i && f >= o->press[p].first && f < o->press[p].first + o->press[p].count)
					on = 1;
			c->set_button(i, on);
		}
		for (int a = 0; a < o->axes; a++)
		{
			const long first = o->axis[a].first, n = o->axis[a].count;
			if (f == first) c->set_axis(o->axis[a].index, o->axis[a].value);
			if (f == first + n) c->set_axis(o->axis[a].index, 0);
		}
		c->frame();
		if (!c->input_was_read()) lag++;
		if (f % o->report == 0 || f == o->frames)
		{
			int w, h, n;
			const uint32_t *v = c->video(&w, &h);
			const int16_t *a = c->audio(&n);
			printf("frame %5ld ram %016" PRIx64 " vid %dx%d %016" PRIx64 " aud %d %016" PRIx64 " lag %ld\n", f,
			       gate_ram_hash(c), w, h, gate_fnv(0, v, (size_t)w * h * 4), n,
			       gate_fnv(0, a, (size_t)n * 4), lag);
			fflush(stdout);
		}
	}
	if (o->dumpDomain)
	{
		int found = 0;
		for (int i = 0; i < c->domain_count(); i++)
			if (!strcmp(c->domain_name(i), o->dumpDomain))
			{
				FILE *f = fopen(o->dumpPath, "wb");
				if (f) { fwrite(c->domain_ptr(i), 1, (size_t)c->domain_size(i), f); fclose(f); }
				found = 1;
			}
		if (!found) { fprintf(stderr, "no memory domain '%s'\n", o->dumpDomain); return 1; }
	}
	if (o->dumpDomains)
	{
		char path[1024];
		snprintf(path, sizeof path, "%s/domains", o->dumpDomains);
		FILE *list = fopen(path, "w");
		for (int i = 0; i < c->domain_count(); i++)
		{
			char name[512];
			snprintf(name, sizeof name, "%s", c->domain_name(i));
			for (char *p = name; *p; p++) if (*p == '/' || *p == ':') *p = '_';
			snprintf(path, sizeof path, "%s/%03d-%s", o->dumpDomains, i, name);
			FILE *f = fopen(path, "wb");
			if (f) { fwrite(c->domain_ptr(i), 1, (size_t)c->domain_size(i), f); fclose(f); }
			if (list) fprintf(list, "%d %s %lld\n", i, c->domain_name(i), (long long)c->domain_size(i));
		}
		if (list) fclose(list);
	}
	if (o->savedataOut)
		for (int i = 0; i < c->save_count(); i++)
		{
			char path[1024];
			snprintf(path, sizeof path, "%s/%s", o->savedataOut, c->save_name(i));
			FILE *f = fopen(path, "wb");
			if (f) { fwrite(c->save_data(i), 1, (size_t)c->save_size(i), f); fclose(f); }
		}
	if (o->vidOut)
	{
		int w, h;
		const uint32_t *v = c->video(&w, &h);
		FILE *f = fopen(o->vidOut, "wb");
		if (f) { fprintf(f, "%d %d\n", w, h); fwrite(v, 4, (size_t)w * h, f); fclose(f); }
	}
	return 0;
}

#endif
