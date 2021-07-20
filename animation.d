import std.stdio;
import std.math;
import std.conv : to;

import core.sys.posix.stdio;
import core.sys.posix.termios;
import core.sys.posix.sys.select;

import frp;


struct Point2D {
    int x; int y;

    void draw() {
        write("\033[",y,";",x,"H\033[7m \033[0m");
        std.stdio.stdout.flush();
    }
}


void main() {

    float time_update = 0.0001;

    /*** REACTIVE COMPONENT DEFINITIONS ***/

    auto frame    = event(0);
    auto center_x = event(50);
    auto center_y = event(40);
    auto radius   = event(15);

    auto time     = mixin(event!q{
        return frame() * time_update;
    });

    auto center   = mixin(event!q{
        return Point2D(center_x(), center_y());
    });

    auto point    = mixin(event!q{
        float x = center().x + 2*radius()*cos(time());
        float y = center().y + radius()*sin(time());
        return Point2D(x.to!int, y.to!int);

    });

    auto satelite = mixin(event!q{
        float x = point().x + 10*cos(10*time());
        float y = point().y +  5*sin(10*time());
        return Point2D(x.to!int, y.to!int);
    });



    /*** HANDLER DEFINITIONS ***/

    void clear_screen() {
        write("\033[2J");
        std.stdio.stdout.flush();
        center().draw();
    }

    radius.observe((r) { clear_screen(); });
    center.observe((p) { clear_screen(); });

    frame.observe((f) {
        if (frame() % 1000 == 0) clear_screen();
        write("\033[0;0HFrame: ", frame());
        std.stdio.stdout.flush();
    });

    point.observe((p) { p.draw(); });
    satelite.observe((p) { p.draw(); });



    /*** SYSTEM SETUP ***/

    int stdin_num = core.sys.posix.stdio.fileno(core.sys.posix.stdio.stdout);

    // setup the terminal to disable buffering and echoing
    termios term;
    tcgetattr(stdin_num, &term);
    term.c_lflag &= ~ECHO & ~ICANON;
    tcsetattr(stdin_num, TCSANOW, &term);

    // setup for select()
    fd_set rfds;
    timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 50;
    int retval;



    /*** ANIMATION LOOP ***/

    while (true) {

        // loop's setup to listen on stdin
        FD_ZERO(&rfds);
        FD_SET(0, &rfds);
        retval = select(stdin_num, &rfds, null, null, &tv);

        if (retval == 0) { // nothing in stdin buffer, advance time
            frame.transform(f => f+1);
        } else switch (getchar()) { // controls
            case 'w': center_y.transform(y => y-1); break;
            case 's': center_y.transform(y => y+1); break;
            case 'a': center_x.transform(x => x-1); break;
            case 'd': center_x.transform(x => x+1); break;
            case 'q': radius  .transform(r => r-1); break;
            case 'e': radius  .transform(r => r+1); break;
            default: break;
        }
    }

}
