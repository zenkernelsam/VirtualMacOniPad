// Pure parser test: never invokes launcher privileges, launchctl or injection.
#define main productionLauncherMain
#include "../../vz/install/install_launcher.c"
#undef main

static void require(int ok, const char *message)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

int main(void)
{
    const char *valid = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const char *uppercase = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F";
    unsigned char token[32];
    require(decode_sep_token(valid, token), "64 hex accepted");
    for (unsigned i = 0; i < sizeof(token); i++) require(token[i] == i, "exact decoded bytes");
    require(decode_sep_token(uppercase, token), "uppercase hex accepted");
    require(!decode_sep_token(NULL, token), "null rejected");
    require(!decode_sep_token("", token), "empty rejected");
    char malformed[66];
    strcpy(malformed, valid); malformed[63] = 0;
    require(!decode_sep_token(malformed, token), "63 characters rejected");
    strcpy(malformed, valid); malformed[64] = '0'; malformed[65] = 0;
    require(!decode_sep_token(malformed, token), "65 characters rejected");
    strcpy(malformed, valid); malformed[31] = 'g';
    require(!decode_sep_token(malformed, token), "non-hex rejected");
    strcpy(malformed, valid); malformed[0] = '-';
    require(!decode_sep_token(malformed, token), "option injection rejected");
    strcpy(malformed, valid); malformed[5] = '\n';
    require(!decode_sep_token(malformed, token), "newline rejected");
    puts("PASS strict 64-hex launcher parser; no system action ran");
    return 0;
}
