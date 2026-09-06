package demo;

enum Shape {
	Dot;
	Circle(r:Float);
}

typedef Point = {x:Float, y:Float};

abstract Meters(Float) from Float to Float {
	public inline function new(v:Float) {
		this = v;
	}

	public function toFloat():Float {
		return this;
	}
}

enum abstract Level(Int) {
	var Low = 0;
	var High = 1;
}
