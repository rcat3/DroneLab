// What the travel cases' pictures share: the case, closed, or open with the
// housing (its children) in it. Included after the case's design.

case_color = "#2e6f8e";
clasp_color = "#c8c8cc";
lid_open = 110;     // how far the lid is turned back on its hinge, in degrees
clasp_open = 70;    // and how far the clasp swings out from the lid

// Turns its children about the hinge's axis, by a
module about_hinge(a) translate([0, hinge_y, case_split]) rotate([a, 0, 0]) translate([0, -hinge_y, -case_split]) children();
// and about the clasp's pin
module about_pin(a) translate([0, clasp_y, pivot_z]) rotate([a, 0, 0]) translate([0, -clasp_y, -pivot_z]) children();

module case_scene(open)
{
    color(case_color) case_bottom();
    about_hinge(open ? lid_open : 0)
    {
        color(case_color) case_lid();
        color(clasp_color) about_pin(open ? -clasp_open : 0) clasp();
    }
    if (open) children();
}
