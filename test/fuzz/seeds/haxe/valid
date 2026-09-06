package demo;

import demo.util.Fmt;
using StringTools;

class Greeter extends Base implements IGreet {
	public var name(default, null):String;

	public function new(name:String) {
		super();
		this.name = name;
	}

	public function greet():String {
		var f = new Fmt();
		return f.pad(name) + Fmt.shout(name) + tag() + name.trim();
	}
}
