package demo;

import demo.Shape;
import demo.util.Fmt as F;
#if sys
import sys.io.File;
#end

final GREETING_PREFIX = "hi";

function area(s:Shape):Float {
	switch (s) {
		case Dot:
			return 0;
		case Circle(r):
			return 3.14 * r * r;
	}
}

class Main {
	static function main() {
		var g = new Greeter("x");
		trace(g.greet());
		var c = Circle(2.0);
		var m = new Meters(1.5);
		flow([1, 2, 3]);
		trace(area(c) + m.toFloat());
		var shout = function(s:String) return F.shout(s);
		trace(shout(GREETING_PREFIX));
	}

	static function flow(xs:Array<Int>):Int {
		var t = 0;
		for (x in xs) {
			if (x > 1 && x < 9 || x == 0) {
				t += x;
			} else if (x < 0) {
				t -= x;
			}
		}
		while (t > 100) t--;
		do {
			t++;
		} while (t < 3);
		switch (t) {
			case 1:
				t = 2;
			case 2 | 3:
				t = 4;
			default:
				t = 0;
		}
		try {
			risky(t);
		} catch (e:String) {
			t = -1;
		} catch (e:Dynamic) {
			t = -2;
		}
		var q = t > 0 ? 1 : 0;
		function inner(k:Int):Int {
			return k + q;
		}
		return inner(q);
	}

	static function risky(t:Int) {
		if (t > 5) {
			throw "big";
		}
	}
}
