package;

import flixel.FlxState;
import asciilib.Game;
import asciilib.backends.flixel.*;
import flixel.graphics.FlxGraphic;

class PlayState extends FlxState
{
	var game:Game;

	override public function create()
	{
		super.create();
		game = new Game("Ascii Game", 40, 24, 8, 12, new AsciiGameLogic(), new FlxAssetsBackend(),
			new FlxGraphicsBackend(this, FlxGraphic.fromAssetKey("assets/images/size12.png"),
				"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz,.;:/?!@#$%^&*()-_=+[]{}~ÁÉÍÑÓÚÜáéíñóúü¡¿0123456789\"'<>|"));
	}

	override public function update(elapsed:Float)
	{
		super.update(elapsed);
		game.update(elapsed);
		game.draw();
	}
}
