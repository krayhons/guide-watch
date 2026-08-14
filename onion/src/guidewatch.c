/*
 * guidewatch.c — in-game guide popup daemon for OnionOS (Miyoo Mini Plus)
 *
 * What it does:
 *   - Watches /mnt/SDCARD/.tmp_update/cmd_to_run.sh to detect game launches
 *     (same file Onion's own runtime uses).
 *   - If a "<ROM base name>.txt" guide sits next to the ROM, gives one short
 *     rumble pulse once RetroArch is up ("a guide exists for this game").
 *   - Watches /dev/input/event0 for the combo: hold L2+R2, then press Down.
 *   - On combo: uses Onion's quick-switch mechanism (same one GLO's
 *     restart/core-swap uses). The game's launch command is saved, the
 *     cmd_to_run.sh file is swapped for the open_guide.sh wrapper, and
 *     RetroArch is asked to quit via its network command (it auto-saves).
 *     Onion's runtime then executes the wrapper: Ebook Reader full screen on
 *     a clean display. When the reader exits (MENU release), the wrapper
 *     restores the original command with /tmp/force_auto_load_state set, so
 *     the game relaunches exactly where it was.
 *
 *   v1 tried SIGSTOP-ing RetroArch and drawing the reader over it — on the
 *   Mini Plus the frozen RA frame stays composited on top, so the reader
 *   ran invisibly. Quitting and relaunching through the runtime is the only
 *   display path this hardware supports (it's also what GameSwitcher does).
 *
 * Facts verified against OnionUI/Onion source (2026-08-13/14):
 *   - cmd_to_run.sh path + "is this a game" test: src/common/system/state.h
 *   - runtime loop re-executes cmd_to_run.sh whenever it exists:
 *     runtime.sh check_game / check_main_ui
 *   - RA quit = UDP "QUIT" to 127.0.0.1:55355 (auto-saves state):
 *     src/keymon/menuButtonAction.h terminate_retroarch, utils/retroarch_cmd.c
 *   - resume flag /tmp/force_auto_load_state: runtime.sh override_game_core
 *   - button codes (L2=KEY_TAB, R2=KEY_BACKSPACE): src/common/system/keymap_hw.h
 *   - rumble motor = GPIO 48, active low: src/common/system/rumble.h
 *   - startup hook dir (.tmp_update/startup): runtime.sh
 *   - pixel-reader takes a book path as argv[1] and also auto-opens
 *     "book_path" from its activity store: pixel-reader src/reader/main.cpp
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SELFTEST
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

#define CMD_PATH "/mnt/SDCARD/.tmp_update/cmd_to_run.sh"
#define EVENT_DEV "/dev/input/event0"
#define READER_CFG "/mnt/SDCARD/App/PixelReader/reader.cfg"
#define WRAPPER "/mnt/SDCARD/App/GuideWatch/open_guide.sh"
#define RESUME_TMP "/tmp/guidewatch_resume.sh"
#define GUIDE_TMP "/tmp/guidewatch_guide"
#define STORE_FALLBACK "/mnt/SDCARD/Saves/CurrentProfile/states/PixelReader"
#define GPIO_EXPORT "/sys/class/gpio/export"
#define GPIO_DIR "/sys/class/gpio/gpio48/direction"
#define GPIO_VAL "/sys/class/gpio/gpio48/value"

/* Onion HW key codes (keymap_hw.h): L2=KEY_TAB, R2=KEY_BACKSPACE, Down=KEY_DOWN */
#define BTN_L2 15
#define BTN_R2 14
#define BTN_DOWN 108

#define PATHLEN 512

/* ---------- pure helpers (also compiled by the self-test) ---------- */

/*
 * Extract the last double-quoted string from the launch command — Onion's
 * runtime rewrites cmd_to_run.sh so the ROM path is always the last quoted
 * argument. Un-escapes the "\$" that runtime.sh inserts for literal dollars.
 * Returns false if there is no quoted argument.
 */
static bool parse_rom_path(const char *cmd, char *out, size_t outlen)
{
    const char *end = strrchr(cmd, '"');
    if (!end || end == cmd)
        return false;
    const char *start = end - 1;
    while (start > cmd && *start != '"')
        start--;
    if (*start != '"')
        return false;
    start++;
    size_t n = 0;
    while (start < end && n < outlen - 1) {
        if (start[0] == '\\' && start[1] == '$')
            start++; /* "\$" -> "$" */
        out[n++] = *start++;
    }
    out[n] = '\0';
    return n > 0;
}

/* "/Roms/SFC/Game v1.2.sfc" -> "/Roms/SFC/Game v1.2.txt" (same convention as
 * guides.retromodlab.com: guide = exact ROM base name + .txt) */
static bool guide_path_for_rom(const char *rom, char *out, size_t outlen)
{
    const char *dot = strrchr(rom, '.');
    const char *slash = strrchr(rom, '/');
    size_t stem = (dot && (!slash || dot > slash)) ? (size_t)(dot - rom) : strlen(rom);
    if (stem + 5 > outlen)
        return false;
    memcpy(out, rom, stem);
    strcpy(out + stem, ".txt");
    return true;
}

/* Mirror of state.h check_isRetroArch()'s command test */
static bool cmd_is_game(const char *cmd)
{
    return strstr(cmd, "retroarch") || strstr(cmd, "/mnt/SDCARD/Emu/") ||
           strstr(cmd, "/mnt/SDCARD/RApp/");
}

/* Read "store_path=..." from reader.cfg text; fall back to Onion's default */
static void parse_store_path(const char *cfg, char *out, size_t outlen)
{
    strncpy(out, STORE_FALLBACK, outlen - 1);
    out[outlen - 1] = '\0';
    if (!cfg)
        return;
    const char *p = strstr(cfg, "store_path=");
    if (!p || (p != cfg && p[-1] != '\n'))
        return;
    p += strlen("store_path=");
    size_t n = 0;
    while (*p && *p != '\n' && *p != '\r' && n < outlen - 1)
        out[n++] = *p++;
    if (n > 0)
        out[n] = '\0';
}

#ifdef SELFTEST
#include <assert.h>
int main(void)
{
    char buf[PATHLEN];

    assert(parse_rom_path("LD_PRELOAD=x.so /a/launch.sh \"/Roms/SFC/Game.sfc\"\n", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/SFC/Game.sfc"));
    assert(parse_rom_path("run \"/Roms/PS/Disc 1.m3u\" ", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/PS/Disc 1.m3u"));
    assert(parse_rom_path("run \"/Roms/A\\$B.gba\"", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/A$B.gba"));
    assert(!parse_rom_path("no quotes here", buf, sizeof(buf)));

    assert(guide_path_for_rom("/Roms/SFC/Game v1.2.sfc", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/SFC/Game v1.2.txt"));
    assert(guide_path_for_rom("/Roms/PS/Final Fantasy IX.m3u", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/PS/Final Fantasy IX.txt"));
    assert(guide_path_for_rom("/Roms/x/noext", buf, sizeof(buf)));
    assert(!strcmp(buf, "/Roms/x/noext.txt"));

    assert(cmd_is_game("cd /mnt/SDCARD/RetroArch; ./retroarch -L core \"/Roms/g.sfc\""));
    assert(!cmd_is_game("/mnt/SDCARD/App/PixelReader/launch.sh"));

    parse_store_path("store_path=/mnt/SDCARD/custom\n", buf, sizeof(buf));
    assert(!strcmp(buf, "/mnt/SDCARD/custom"));
    parse_store_path("other=1\n", buf, sizeof(buf));
    assert(!strcmp(buf, STORE_FALLBACK));
    parse_store_path(NULL, buf, sizeof(buf));
    assert(!strcmp(buf, STORE_FALLBACK));

    puts("selftest OK");
    return 0;
}
#else

/* ---------- device-side code ---------- */

static bool exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

static char *read_file(const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp)
        return NULL;
    static char buf[2048];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';
    return buf;
}

static void write_str(const char *path, const char *s)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (fd < 0)
        return;
    write(fd, s, strlen(s));
    close(fd);
}

/* same /proc/<pid>/comm prefix search Onion's process_searchpid() uses */
static pid_t searchpid(const char *name)
{
    DIR *dp = opendir("/proc");
    struct dirent *d;
    char fname[288], comm[128];
    pid_t found = 0;
    size_t len = strlen(name);
    if (!dp)
        return 0;
    while ((d = readdir(dp))) {
        pid_t pid = atoi(d->d_name);
        if (pid <= 2 || pid == getpid())
            continue;
        snprintf(fname, sizeof(fname), "/proc/%d/comm", pid);
        FILE *fp = fopen(fname, "r");
        if (!fp)
            continue;
        if (fscanf(fp, "%127s", comm) == 1 && !strncmp(comm, name, len))
            found = pid;
        fclose(fp);
        if (found)
            break;
    }
    closedir(dp);
    return found;
}

static pid_t find_retroarch(void)
{
    pid_t pid = searchpid("retroarch");
    return pid ? pid : searchpid("ra32");
}

/* GPIO 48 drives the rumble motor, active low (rumble.h) */
static void rumble_pulse(int ms)
{
    write_str(GPIO_EXPORT, "48"); /* fails silently if already exported */
    write_str(GPIO_DIR, "out");
    write_str(GPIO_VAL, "0");
    usleep(ms * 1000);
    write_str(GPIO_VAL, "1");
}

static void mkdir_p(const char *path)
{
    char tmp[PATHLEN];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

/* Pre-seed pixel-reader's activity store so even a reader build without
 * argv support opens straight onto the guide. */
static void write_activity(const char *guide)
{
    char store[PATHLEN], path[PATHLEN + 16], body[2 * PATHLEN + 32];
    parse_store_path(read_file(READER_CFG), store, sizeof(store));
    mkdir_p(store);

    char dir[PATHLEN];
    strncpy(dir, guide, sizeof(dir) - 1);
    dir[sizeof(dir) - 1] = '\0';
    char *slash = strrchr(dir, '/');
    if (slash)
        *slash = '\0';

    snprintf(path, sizeof(path), "%s/activity", store);
    snprintf(body, sizeof(body), "book_path=%s\nbrowser_path=%s/\n", guide, dir);
    write_str(path, body);
}

/* ask RetroArch to quit the same way keymon does: UDP "QUIT" to localhost
 * (Onion forces network_cmd_enable=true; RA auto-saves its state on quit) */
static int retroarch_udp_quit(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(55355);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ssize_t rc = sendto(fd, "QUIT", 4, 0, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
    return rc == 4 ? 0 : -1;
}

/* wait for a pid to disappear; true if it did */
static bool wait_gone(pid_t pid, int max_ms)
{
    for (int t = 0; t < max_ms; t += 100) {
        if (kill(pid, 0) != 0)
            return true;
        usleep(100000);
    }
    return kill(pid, 0) != 0;
}

/*
 * The quick-switch handoff. Returns true if the game is quitting and the
 * runtime will execute the reader wrapper next.
 */
static bool swap_to_reader(const char *guide)
{
    pid_t ra = find_retroarch();
    if (!ra || !exists(guide))
        return false;

    char *cmd = read_file(CMD_PATH);
    if (!cmd || !cmd_is_game(cmd))
        return false;

    /* stash the game's launch command + guide path for the wrapper */
    write_str(RESUME_TMP, cmd);
    write_str(GUIDE_TMP, guide);
    write_activity(guide);

    /* hand the runtime our wrapper. Must not contain "Roms"/"retroarch"
     * substrings or runtime.sh would treat it as a game launch. */
    write_str(CMD_PATH, "#!/bin/sh\nexec " WRAPPER "\n");

    /* CRITICAL: without this flag, runtime.sh check_switcher() DELETES
     * cmd_to_run.sh when the game exits and falls back to MainUI. The flag
     * is consumed once per exit (same mechanism Onion's quick switch uses). */
    write_str("/tmp/quick_switch", "");

    rumble_pulse(50);

    /* quit RA (it saves state); escalate politely if the UDP packet is lost */
    retroarch_udp_quit();
    if (!wait_gone(ra, 3000)) {
        kill(ra, SIGTERM);
        if (!wait_gone(ra, 3000)) {
            /* RA won't die — undo the swap so nothing weird happens later.
             * NB: read_file's static buffer still holds the game command. */
            write_str(CMD_PATH, cmd);
            unlink(RESUME_TMP);
            unlink(GUIDE_TMP);
            unlink("/tmp/quick_switch");
            return false;
        }
    }
    return true;
}

static void on_term(int sig)
{
    (void)sig;
    write_str(GPIO_VAL, "1"); /* motor off, just in case */
    _exit(0);
}

int main(void)
{
    /* single instance ("guidewatch" fits the 15-char comm limit) */
    if (searchpid("guidewatch"))
        return 0;

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    int fd = -1;
    enum { ST_IDLE, ST_WAIT_RA, ST_ARMED, ST_PASSIVE } state = ST_IDLE;
    char guide[PATHLEN] = "";
    static char last_cmd[2048] = "";
    bool l2 = false, r2 = false;
    time_t last_check = 0;

    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("guidewatch: started\n");

    while (1) {
        if (fd < 0) {
            fd = open(EVENT_DEV, O_RDONLY | O_NONBLOCK);
            if (fd < 0) {
                sleep(1);
                continue;
            }
        }

        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int rc = poll(&pfd, 1, 1000);

        /* ~1/sec: track game state via cmd_to_run.sh */
        time_t now = time(NULL);
        if (now != last_check) {
            last_check = now;
            if (!exists(CMD_PATH)) {
                if (state != ST_IDLE)
                    printf("guidewatch: game ended\n");
                state = ST_IDLE;
                last_cmd[0] = '\0';
            }
            else {
                /* Re-parse whenever the command CONTENT changes, not only
                 * when the file reappears: GameSwitcher / quick switch swap
                 * games without the file ever going away, and the guide must
                 * follow the game (learned the hard way: FF9 opened the
                 * Castlevania guide). */
                char *cmd = read_file(CMD_PATH);
                if (cmd && strcmp(cmd, last_cmd) != 0) {
                    strncpy(last_cmd, cmd, sizeof(last_cmd) - 1);
                    last_cmd[sizeof(last_cmd) - 1] = '\0';
                    char rom[PATHLEN];
                    if (cmd_is_game(cmd) &&
                        parse_rom_path(cmd, rom, sizeof(rom)) &&
                        guide_path_for_rom(rom, guide, sizeof(guide)) &&
                        exists(guide)) {
                        printf("guidewatch: guide found: %s\n", guide);
                        state = ST_WAIT_RA;
                    }
                    else {
                        state = ST_PASSIVE; /* app, wrapper, or no guide */
                    }
                }
                if (state == ST_WAIT_RA && find_retroarch()) {
                    printf("guidewatch: retroarch up, guide armed\n");
                    rumble_pulse(100); /* the "this game has a guide" cue */
                    state = ST_ARMED;
                }
            }
        }

        if (rc <= 0 || !(pfd.revents & POLLIN)) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                close(fd);
                fd = -1;
            }
            continue;
        }

        struct input_event ev;
        while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
            if (ev.type != EV_KEY)
                continue;
            if (ev.code == BTN_L2)
                l2 = ev.value != 0;
            else if (ev.code == BTN_R2)
                r2 = ev.value != 0;
            else if (ev.code == BTN_DOWN && ev.value == 1 && l2 && r2 &&
                     state == ST_ARMED) {
                printf("guidewatch: combo, swapping to reader\n");
                if (swap_to_reader(guide)) {
                    /* re-arm (with rumble cue) when the game comes back */
                    state = ST_WAIT_RA;
                    printf("guidewatch: reader handoff done\n");
                }
                l2 = r2 = false;
            }
        }
    }
    return 0;
}

#endif /* SELFTEST */
