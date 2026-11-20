#include "my_application.h"

#include <stdio.h>
#include <string.h>

// --profile NAME (or --profile=NAME): run as another person beside the usual
// one, with files of their own (lib/comm/app_profile.dart). The Dart side
// reads it from the same arguments.
static bool profile_ok(const char* name) {
  size_t n = strlen(name);
  if (n < 1 || n > 32) return false;
  for (size_t i = 0; i < n; i++) {
    char c = name[i];
    if (!g_ascii_isalnum(c) && c != '_') return false;
  }
  return true;
}

int main(int argc, char** argv) {
  const char* profile = nullptr;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--profile") == 0 && i + 1 < argc) {
      profile = argv[i + 1];
    } else if (strncmp(argv[i], "--profile=", 10) == 0) {
      profile = argv[i] + 10;
    } else if (strcmp(argv[i], "--profile") == 0) {
      profile = "";
    }
  }
  if (profile != nullptr && !profile_ok(profile)) {
    fprintf(stderr, "--profile NAME: up to 32 letters, digits and _\n");
    return 2;
  }
  if (profile != nullptr && strcmp(profile, "default") == 0) profile = nullptr;
  g_autoptr(MyApplication) app = my_application_new(profile);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
