kind additive3pp;
domain private additive3pp;

private int classify (int x) {
    havoc private int y;
    return y;
}
private bool classify (bool x) {
    havoc private bool y;
    return y;
}

int operator +  (private int x, private int y)  { return  0; }
int operator +  (private int x, int y)          { return  1; }
int operator +  (int x, private int y)          { return  2; }
int operator +  (private int x, bool y)         { return  3; }
int operator +  (private int x, private bool y) { return  4; }

int operator -  (private int x, private int y)  { return  5; }
int operator *  (private int x, private int y)  { return  6; }
int operator /  (private int x, private int y)  { return  7; }
int operator %  (private int x, private int y)  { return  8; }
int operator == (private int x, private int y)  { return  9; }
int operator <  (private int x, private int y)  { return 10; }
int operator <= (private int x, private int y)  { return 11; }
int operator >  (private int x, private int y)  { return 12; }
int operator >= (private int x, private int y)  { return 13; }
int operator && (private int x, private int y)  { return 14; }
int operator || (private int x, private int y)  { return 15; }

int operator ! (private bool b) { return 42; }
int operator - (private int x) { return 43; }
int operator - (private bool x) { return 44; }

void main () {
    private int x;
    private bool b;

    assert (x +  x     ==  0);
    assert (x +  0     ==  (1::int));
    assert (1 +  x     ==  2);
    assert (x +  true  ==  3);
    assert (x +  b     ==  4);
    assert (x -  x     ==  5);
    assert (x *  x     ==  6);
    assert (x /  x     ==  7);
    assert (x %  x     ==  8);
    assert (x == x     ==  (9::int));
    assert (x <  x     == (10::int));
    assert (x <= x     == (11::int));
    assert (x >  x     == (12::int));
    assert (x >= x     == (13::int));
    assert ((x && x)   == (14::int));
    assert ((x || x)   == 15);
    
    assert ((! b) == (42::int));
    assert ((- x) == 43);
    assert ((- b) == (44::int));
}
