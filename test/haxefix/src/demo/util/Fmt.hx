package demo.util;

class Fmt {
	public function new() {}

	public function pad(s:String):String {
		return " " + s;
	}

	public static function shout(s:String):String {
		return s.toUpperCase();
	}
}
