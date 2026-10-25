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

	./scripts/build-engine.sh
	./scripts/build-sympy.sh
	./make-app.sh
Usually it is enougn. The app will be in ./dist folder from where you may copy it to Application folder.

## Choose custom model for image editing

1. Choose a model from a list. There are predefined models hardcoded into the application and Custom model. Choose it.
2. Than you have to choose an engine. 
   - sd-cli
   - iopaint
   - llama
3. sd-cli provides support for most models. Others will be consider below.
4. Than you choose model type: "checkpoint" or "diffusion"
   - checkpoint:  like SD 1,2,3, SDXL, it is usually full solution
   - diffusion:  like Z-turbo, Flux, Qwen_Image, requires addition tensors

Look requirements for your choosed model, download all required files from https://huggingface.co/, for example for Flex.2_Preview you have to download

- vae: ae-f16.gguf
- text_encoders: t5-XX: t5-v1_1-xxl-encoder-Q4_K_M.gguf and CLIP: clip_l.safetensors

while for SD-2-Inpainting you need model and textencoder: Qwen3-4B-Instruct-2507-Q8_0.gguf

Than you have to point to your images if needed:

- initial image, not needed for text-to-image models
- mask image, required for Inpainting models. There is also a procedure to draw your own mask
- control image, for some complex models like Flex.2
- reference images, for example for Qwen-Image.
- vision projector: mmproj tensors for reading details in images, if needed

## IOPAINT engine

This is a python application can be used from ToshLLM instead of sd-cli engine. To install call

	pip3 install iopaint
	

Install also certificates

	/Applications/Python3.12/Install\ Certificates.command
	
Moreover to use iopaint it is recommended to create virtual environment

	# Create a forder for virtual environment
	mkdir -p ~/.iopaint-env

	# Create virtual environment
	python3 -m venv ~/.iopaint-env

	# Activate
	source ~/.iopaint-env/bin/activate

	# Install iopaint 
	pip install iopaint

	# Check
	iopaint run --help

	# Deactivate and exit
	deactivate


So you will not have python versions conflict with future updates.
