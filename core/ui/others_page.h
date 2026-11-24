#ifndef RCAT_OTHERS_PAGE_H
#define RCAT_OTHERS_PAGE_H

/*
 * A feature's "Others" page: who may send it commands over the comm channel
 * (see app/others.h), by the wearer's rules, which their app sets: Off, Ask
 * or Anyone, with a button to switch it Off here, who's allowed, and who
 * sent the last one.
 */

#include "app/others.h"
#include "ui/ui_internal.h"

/* Add the page for one kind of command to a feature, after its others.
 * Returns NULL, and adds nothing, on boards with neither the comm channel
 * nor direct comms. */
lv_obj_t *ui_others_page_add(ui_feature_t *feature, others_kind_t kind);

#endif
