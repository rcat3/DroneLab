#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Creates a new Flutter-based application, as the profile [profile]
 * (null for the usual one).
 *
 * Returns: a new #MyApplication.
 */
MyApplication* my_application_new(const char* profile);

#endif  // FLUTTER_MY_APPLICATION_H_
