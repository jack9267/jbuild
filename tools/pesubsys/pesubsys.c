/* pesubsys - stamp a PE image's OS and subsystem version into its optional header.
 *
 * The MSVC linker floors /SUBSYSTEM at 5.01 (x86) / 5.02 (x64) and silently stamps 6.0 for anything
 * lower (LNK4010), so a Windows 2000 (5.0) target cannot be produced at link time. The build links
 * at the floor and then runs this to overwrite the four version WORDs with the real value. OS and
 * subsystem are both set, since the loader gates on both.
 *
 *     pesubsys <image> <major> <minor>
 *
 * The checksum is recomputed only if the linker wrote one (a /RELEASE-less build leaves it 0, and the
 * loader does not verify an ordinary user-mode image's checksum anyway). Not wired into any solution:
 * a one-time wrapper (pesubsys.cmd) builds it on first use and caches the exe beside this source.
 */
#include <stdio.h>
#include <stdlib.h>

static unsigned long  rd32(const unsigned char *p) { return (unsigned long)(p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned long)p[3] << 24)); }
static void           wr16(unsigned char *p, unsigned short v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); }
static void           wr32(unsigned char *p, unsigned long v)  { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24); }

/* The PE image checksum, matching imagehlp!CheckSumMappedFile: a folded 16-bit ones'-complement sum
 * over the whole file with the checksum field taken as zero, plus the file length. */
static unsigned long pe_checksum(const unsigned char *buf, size_t len, size_t ckOff)
{
	unsigned long sum = 0;
	size_t i;

	for (i = 0; i + 1 < len; i += 2)
	{
		unsigned int w = (i == ckOff || i == ckOff + 2) ? 0u : (unsigned int)(buf[i] | (buf[i + 1] << 8));
		sum += w;
		sum = (sum >> 16) + (sum & 0xffff);
	}

	if (len & 1)
	{
		sum += buf[len - 1];
		sum = (sum >> 16) + (sum & 0xffff);
	}

	sum = (sum >> 16) + (sum & 0xffff);
	return (unsigned long)(unsigned short)sum + (unsigned long)len;
}

int main(int argc, char **argv)
{
	const char *path;
	int major, minor;
	FILE *f;
	long fsize;
	size_t len, pe, opt, ckOff;
	unsigned char *buf;

	if (argc != 4)
	{
		fprintf(stderr, "usage: pesubsys <image> <major> <minor>\n");
		return 2;
	}

	path = argv[1];
	major = atoi(argv[2]);
	minor = atoi(argv[3]);

	f = fopen(path, "rb");
	if (!f)
	{
		fprintf(stderr, "pesubsys: cannot open %s\n", path);
		return 1;
	}

	fseek(f, 0, SEEK_END);
	fsize = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (fsize < 0x40)
	{
		fprintf(stderr, "pesubsys: %s is too small to be a PE image\n", path);
		fclose(f);
		return 1;
	}

	len = (size_t)fsize;
	buf = (unsigned char *)malloc(len);
	if (!buf)
	{
		fprintf(stderr, "pesubsys: out of memory\n");
		fclose(f);
		return 1;
	}

	if (fread(buf, 1, len, f) != len)
	{
		fprintf(stderr, "pesubsys: failed to read %s\n", path);
		fclose(f);
		free(buf);
		return 1;
	}
	fclose(f);

	if (buf[0] != 'M' || buf[1] != 'Z')
	{
		fprintf(stderr, "pesubsys: %s is not a PE image (no MZ)\n", path);
		free(buf);
		return 1;
	}

	pe = (size_t)rd32(buf + 0x3C);
	if (pe + 0x44 > len || buf[pe] != 'P' || buf[pe + 1] != 'E' || buf[pe + 2] || buf[pe + 3])
	{
		fprintf(stderr, "pesubsys: %s has no PE signature\n", path);
		free(buf);
		return 1;
	}

	/* The optional header. OS/subsystem version and checksum offsets are identical for PE32 and PE32+
	 * (the two differ earlier, at ImageBase, and realign by SectionAlignment at 0x20). */
	opt = pe + 24;
	wr16(buf + opt + 0x28, (unsigned short)major); /* MajorOperatingSystemVersion */
	wr16(buf + opt + 0x2A, (unsigned short)minor); /* MinorOperatingSystemVersion */
	wr16(buf + opt + 0x30, (unsigned short)major); /* MajorSubsystemVersion */
	wr16(buf + opt + 0x32, (unsigned short)minor); /* MinorSubsystemVersion */

	ckOff = opt + 0x40; /* CheckSum */
	if (rd32(buf + ckOff) != 0)
		wr32(buf + ckOff, pe_checksum(buf, len, ckOff));

	f = fopen(path, "wb");
	if (!f)
	{
		fprintf(stderr, "pesubsys: cannot reopen %s for writing\n", path);
		free(buf);
		return 1;
	}

	if (fwrite(buf, 1, len, f) != len)
	{
		fprintf(stderr, "pesubsys: failed to write %s\n", path);
		fclose(f);
		free(buf);
		return 1;
	}

	fclose(f);
	free(buf);
	printf("[pesubsys] %s -> OS/subsystem %d.%d\n", path, major, minor);
	return 0;
}
