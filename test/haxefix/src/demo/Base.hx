package demo;

class Base {
	public static inline var MAX_RETRIES:Int = 3;
	var count:Int = 0;

	public function new() {}

	public function tag():String {
		count++;
		return "base";
	}
}
