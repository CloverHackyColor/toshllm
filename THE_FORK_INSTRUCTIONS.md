#THE FORK INSTRUCTIONS
by Sergey Slice

## The difference from main project by Engelbert Delgado

I am not an author. I just proposed some changes in the project for my convenience
- I prefer custom models vs hard coded because I can download from Hugging Face all I want to test. 
Custom Models have different behaviors and different requirements so some changes in tuning and using are needed.
- I work in light theme so yellow and orange color are not comfortable for me. Change to cyan or light blue or pink.
- Some visual elements I prefer to change. For example I want to see a name of current model to speak with.

## Compilation
	Before compile you should prepare some new tools. It should be created automatically but I saw the message
	"Metal compiler unavailable — embedded source only (slower first load)"
	so I consulted with external AI what to do.
	
	Than do
	- ./scripts/build-engine.sh
	- ./scripts/build-sympy.sh
	- ./make-app.sh
	Usually it is enougn. The app will be in ./dist folder from where you may copy it to Application folder.
	

