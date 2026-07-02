# SRP - Sox Rofi Parser
A token and text-based soundboard leveraging the power of **Rofi** for input and **Sox** for audio output. The parser takes a string either through stdin or as a command-line argument in quotes. At it's core, each token represents a sound sample found by the search term. Tokens are separated by a single space and can have arguments appended to them, such as sox effects. The token is then processed by sox and then played back by paplay or gstreamer.

SRP is functionally similar to a soundbard, except that instead of having fixed binds for each sample, the user can directly enter the name of the sample even in fullscreen applications. This also allows for the application of effects in real-time: the user may choose to play a sound sample normally and then play the same sound sample with a modified speed. Setting it up with something like a virtual audio device, playback of samples can even be done over something like Discord or an online game with voice-chat.

## Core features
In order:
- Text-based soundboard - play a sound sample from your library, leveraging Rofi's search features for fast access.
- Queue system - Multiple sounds can be prompted in the same string, making it possible to create sentences out of individual samples.
- Effects - Add Sox effects to each individual sample one by one, such as changed pitch, tempo or speed.
- Concatenation - instead of just playing sounds one by one, they can be rendered together and then played for gapless playback.
- Mixing - mix two or more sounds together to make them playback at the same time.
- Macros - multiple sounds and effects can be played using a single token.

## Extended features
- Rubberband integration which allows for stretching of time and pitch, basic envelope shapes include curves such as linear, exponential and sinus.
- Regex parsing - uses the standard Linux `find` command to find audio files, which supports regex parsing.
- Random token - play a random token from your sound library by entering '?'.
- Random value - some effects allows the user to randomize the value for the specified effect.
- Extended sox parsing - user may set the target length of an audio as a percentage instead of absolute length in seconds.
- xdotool trigger - During playback, user may specify a key to be held, useful when playing sounds through a push-to-talk.

## Building and dependencies
Using Zig 0.16, simply do:
`zig build-exe srp.zig`

Dependencies are called as sub-processes. `rubberband-cli` is therefor not a required dependency. `sox` and `find` should already be installed on most Linux PCs.


## Usage
### Getting started
Start of by creating a config file for SRP. Name it "srp.cfg" and place it in the same folder as the executable.
The config must contain at least the following two lines:

- `SOUND_FOLDER="/home/user/path/to/sound/library/"` - Set this to the directory of your sound library.
- `SOUND_DEVICE="alsa_output.stereo-output"` - Set this to the name of your pulseaudio device where audio playback will occur. Exact device name may found by using this command: `LANG=C pactl list | grep -A2 'Source #' | grep 'Name: ' | cut -d" " -f2`.

The command pipeline can look something like this, adjust the directories accordingly:

`find ~/Music/soundlibrary/ -type f -printf "%f\n" | rofi -dmenu -matching prefix -i false -no-sort -p "File" | /home/user/srp/srp`

Binding that to a key, it allows the user to have instant access to the prompt, even in fullscreen applications. This is just an example however, rofi may be adjusted to include fuzzy search or any other setting that the user would like rofi to use. SRP can also be used without rofi through the terminal like this: `/home/user/srp/srp "hello"`

### Sox effects
Because tokens are separated by spaces, **sox** effects are added by using a plus and semicolons. Plus denotes effect and semicolons argument for said effect. For example, when using sox natively, an echo may be added as `echo 0.6 0.7 500 0.4`. When added to a token with SRP, the prompt will look more like this: 
- `hello+echo;0.6;0.7;500;0.4`.

Multiple **sox** can be chained together into one single effect by adding **+** for each effect. Effects will then processed by **sox** from left to right. For example: 
- `hello+pitch;200+speed;0.8+reverb;80+reverse`. 

The order becomes important when taking certain effects into account. A reverse reverb or echo can for example be done by reversing the audio before applying the effect, and then reversing the audio back into its normal direction: 
- `hello+reverse+pad;0;5+reverb;80+reverse"`

For more information on **sox** effects, check out the manual here: [sox manual](https://linux.die.net/man/1/sox)

Because of how vast **sox** is, far from every effect and feature has been implemented, but in general, many of the examples listed in the manual can be used for SRP with reformatted prompting. Some effects or arguments that SRP rejects may also be available through the use of **RAWSFX** macros.

### Prompting examples
Given that everything is configured and running, and you have at least a few audio samples in the folder that the config file is pointing to, let's look at a few examples of how SRP can be prompted. Let's assume that we have a few audio files called **hello.ogg**, **there.ogg** and **goodday.ogg**:

```
hello                           # Plays a sample called *hello* from your sound library. This audio file may have an **.ogg**, **.mp3** or **.wav** file extension, with the first two being primarly supported.
hello there goodday             # Plays *hello there goodday* in one sequence, sample after sample.
hello+pitch;300 there           # Plays *hello* with a pitched sound effect and *there* normally. 
{hello there}+pitch;300         # Concatenates *hello* and *there* together as one audio file, and then applies the pitch effect.
hello ?                         # Plays *hello* then a **random** file from the sound library.
hello/there/goodday             # Mixes *hello*, *there* and *goodday* so that they are played back at the very same time.
he* {there goodday}+reverse     # Does a regex search for *he**, which in our example will automatically find *hello*, then concatenates *there* and *goodday*, and then finally plays *hello* and then the concatenated audio in reverse.
hello+speed;?                   # Play hello with a random speed.
{hello}/{there}+speed;0.5:2?    # Pre-render *hello* and *there* separately, mix them and then apply a random speed in the range of 0.5 to 2.
hello!                          # Activate xdotool to hold a key while playing ('Home' by default), usefor for Push-to-Talk purposes.
he??o                           # Regex wildcard parsing for any sounds starting with "he" and ending on "o".
```

### Config
The config file is required to let SRP know which sound library and audio device to use, as mentioned above. Aside from that, there are two optional configuration lines:

- `SOUND_PLAYER="paplay"` - Sets which audio player to play back audio through. For now, only **paplay** and **gstreamer** are supported.
- `SOUND_REPLACEMENT="beep"` - By default, SRP ignores sound tokens if the audio file itself is not found. The user may let SRP play a dummy sound token specified in this line, so that if the prompted sound token is invalid, SRP will play this sound instead.

The config file is also used to store macros and user effects. There are three types of user-defined macros: **USERMACRO**, **USEREFFECT** and **RAWSFX**. The name of the macro is contained within the first set of quotes and the actual macro in the second set of quotes.

- **USERMACRO** is a user defined string that will copy-pasted as if it was prompted directly. It is the first type of token to be parsed by SRP and anything that can be successfully parsed by SRP, can be written as a macro of this type. The user calls a macro of this type by entering and underscore after the macro name.
- **USEREFFECT** is a user defined effect that may contain multiple **sox** effects at once. This type of macro may only contain effects and no sample names; though there is one exception where the same audio sample can be queued multiple times. This type of macro is called as an effect by adding a plus right after the token.
- **RAWSFX** is a user defined effect in the direct format that **sox** uses (spaces instead of **+** and **;**). These macros will not be parsed by SRP; instead they are copy-pasted as-is, which allows this type of macro to do things that SRP normally can't parse. This type of macro is called as an effect by adding a plus right after the token.

Here is what a macro may look like inside of the config file:
- `USERMACRO="h1" "hello there"` - Upon entering **h1_** in the prompt, SRP will play the string of tokens within the second pair of quotes.
- `USEREFFECT="s4" "pitch;-1000+speed;2"` - Upong entering **+s4** after the token in the prompt, SRP will reformat this string into a sox command for both *pitch* and *speed*.
- `RAWSFX="telephone" "highpass 500 lowpass 2000 overdrive 15"` - Upon entering **+telephone** after the token in the prompt, SRP will add the effect verbatim.

### Macros
Macros can become somewhat complex, a **USERMACRO** in particular. It is parsed recursively which means a macro can contain another macro, though by default there is a compiled max limit to how many recursions are allowed to happen. A macro may also contain a virtually endless amount of concatenation nesting, though there is a compiled hard-limit to scope by default.

The purpose of nesting is mostly to prevent gaps during playback, as there is typically a small delay between two tokens during playback. Concatenating them together doesn't only make them seamless, but it allows for effects to be applied on multiple sounds at the same time. As mentioned earlier, concatenation nesting can become arbitrarily complex. Just make sure each opening curly brace has a corresponding closing brace.
Here are two test macros as an example:
- `USERMACRO="curly1"   "{{{hello}+telephone there}+reverb;50}+reverse"`
- `USERMACRO="curly2"   "{{{{{{curly1_}}}}}}{{{{{{man}}}}}}"`

**USERMACRO** supports variables in the form of arguments. Within the macro, the user can declare any string as *$0* to be defined for the macro at run-time. Multiple variables can be added by increasing the number like *$1*, *$2*, and so on. The variable will be replaced by the input the user has given to the macro argument. For example, if `var_` is a macro that contains `$0+pitch;200 there+pitch;$1`, it can be called by typing `var_;hello;300`. The parsed string will result as `hello+pitch;200 there+pitch;300`. This also works recursively, so the user can call a macro with one or more arguments, that corresponds to another macro that contains a string with variables. Macros may also contain multiple instances of a variable, which means that `$0 $0 $0 $0 $1 $2` is a valid macro.

**USEREFFECT** supports a much more limited variable argument that applies on the token itself. This is mainly used for a **USEREFFECT** intended as a repeated effect. If the macro contains *$sound*, it will be treated as a variable effect macro and every instance of *$sound* will be replaced by the token it was applied on. For example, if `s2` is a user effect that contains `$sound+pitch;100 $sound+pitch;300 $sound+pitch;500`, it can be called by typing `hello+s2`. The parsed string will result as `hello+pitch;100 hello+pitch;300 hello+pitch;500`, effectively playing the same sound three times but with different pitches.

Here are two macro examples, one for nesting and one for recursion:
```
USERMACRO="comp1"       "comp2_"
USERMACRO="comp2"       "hello comp3_ comp3_ there"
USERMACRO="comp3"       "hey man comp4_"
USERMACRO="comp4"       "boy comp5_"
USERMACRO="comp5"       "yo yo+pitch;100:200? yo+pitch;200:400?"
```

Entering `comp1_` results in the following string: 

- `hello hey man boy yo yo+pitch;100:200? yo+pitch;200:400? hey man boy yo yo+pitch;100:200? yo+pitch;200:400? there`

### Rubberband
Rubberband is integrated in a slightly fixed manner. Rubberband is prompted as a regular effect but there will be an extra render stage between the **rubberband** effect and any **sox** effect. There are two **rubberband** effects:
- **rbt** - Rubberband timemap effect
- **rbp** - Rubberband pitchmap effect

Consider this prompt: `TOKEN+rbt;MODE;START_SPEED;END_SPEED;START_DURATION;END_DURATION`

The syntax is as follows:
- *MODE* - The speed curve to be used. (0: *Linear*, 1: *Exponential*, 2: *Sine*, 3: *Sine*, 4: *Triangle*, 5: *Square*, 6: *Sawtooth*)
- *START_SPEED* - Starting speed for *Linear* (0) and *Exponential* (1), **amplitude** for the other curve types.
- *END_SPEED* - Ending speed for *Linear* (0) and *Exponential* (1), **frequency** for the other curve types.
- *START_DURATION* - Specify when the effect shall start. Can also be expressed in percentage (e.g. **20p** for 20% of duration).
- *END_DURATION* - Specify effect ending. Can also be expressed in percentage and relative to ending (e.g. **2r** for 2s before end).

For example: 
- `goodday+rbt;0;0.5;4;10p;2.1r`

Will play *goodday*, sliding linearly in tempo from slow-to-fast, starting at a speed of 0.5 and ending with a speed of 4. In addition, the effect starts 10% into the duration of the audio sample and arrives at full speed 2.1 seconds away from its ending.

It is for these types of effects where relative and percentage based arguments really shine because the user can put this prompt into a variable macro and regardless of the duration (which isn't necessarily known to the user), it will always process a similar kind of effect.

Another example:
- `goodday+rbt;2;3;4`

Here we applied a sine wave curve, so instead of a starting speed and ending speed, we have a wave with an amplitude of 3 and a frequency of 4. Note that the frequency is not per seconds, the frequency is merely the amount of cycles per sample or specified range. That means however, that if the start duration is 0 and the end duration is 1, the frequency will be in cycles per seconds.

These two **rubberband** examples may also be modified to use **rbp** instead of **rbt**. This will produce a change in pitch instead of time.

## Background
A friend of mine used to have a server with a music bot that opened and played from YouTube links. We soon figured that this bot could play local audio files, which fit our mutual sense of humor given that we liked sentence mixing, and so we began modifying this bot to include a queuing system and regex syntaxing. Eventually, after trying to prompt up a Python script that could do something similar, I decided to write something in a compiled language from scratch because the script was becoming sluggish. I ended up spending more time on this than I would like to admit but I learned quite a bit from this project.

I had a few more ideas for this project that I would have liked to implement, and there are probably a few quirks, but I was running out of steam and I had to move on. For example, variable effect macros are a bit limited in that you can't stack multiple effect macros. I'm happy with this for now though, so don't expect any big updates for this any time soon.

### Shoutouts
Since this project is basically a front-end for some amazing tools, big shoutouts goes out to these tools and the people behind them:
- Sox - it truly is a swiss-army knife when it comes to audio editing!
- Rofi - will probably make use of this again in future projects
- Rubberband - took me a while to figure out but was a lot of fun to work with when I figured it out
- Zig - I like this language but I wish there was more documentation overall. Even AI can't help you much here.
