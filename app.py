import gradio as gr
#import spaces commenting this out because we won't be able to use ZeroGPU anymore
from huggingface_hub import HfApi, InferenceClient #following github cs2 sample code for token validation
from transformers import pipeline
import os
import time

LOCAL_MODEL = "Qwen/Qwen2.5-0.5B-Instruct"
REMOTE_MODEL = "meta-llama/Llama-3.1-8B-Instruct"

max_tokens = 900
temperature = 0.7
top_p = 0.95

FLAG_FILE_PATH = "/tmp/overload_activate.flag"
FLAG_STALE_AFTER = 15 * 60   # seconds; monitor refreshes the flag each run, so older = monitor is dead
REDUCED_MAX_TOKENS = 150
KNOWN_ACTIONS = {"REDUCE_WORKLOAD", "REJECT_REQUESTS", "BANNER"}

def current_overload_action():
    """None when normal, otherwise REDUCE_WORKLOAD / REJECT_REQUESTS / BANNER."""
    try:
        if time.time() - os.path.getmtime(FLAG_FILE_PATH) > FLAG_STALE_AFTER:
            return None
        with open(FLAG_FILE_PATH) as f:
            first_line = f.readline().strip()
    except OSError:
        return None
    action = first_line.split("=", 1)[1].strip() if first_line.startswith("ACTION=") else ""
    return action if action in KNOWN_ACTIONS else "REDUCE_WORKLOAD"   # flag exists but unreadable: fail toward less load

pipe = pipeline(
    "text-generation",
    model=LOCAL_MODEL,
    dtype="auto",
    device="cpu", #changed to cpu since we won't be using GPU anymore from Huggingface 
)

fancy_css = """
.gradio-container {
    width: 96% !important;
    max-width: none !important;
    background: url("/gradio_api/file=cute_kitchen_background.png") center / cover fixed !important;
}
#app-title,
#app-subtitle,
#model-note {
    background: var(--block-background-fill);
    color: var(--body-text-color);
    padding: var(--block-padding);
    border-radius: var(--block-radius);
}
#app-title,
#app-subtitle {
    text-align: center;
}
@media (max-width: 768px) {
    .gradio-container {
        width: 98% !important;
    }
}
"""


# @spaces.GPU needed to comment this out because we won't be able to use ZeroGPU anymore
def local_generate(
    messages,
    max_tokens,
    temperature,
    top_p,
):
    outputs = pipe(
        messages,
        max_new_tokens=max_tokens,
        do_sample=True,
        temperature=temperature,
        top_p=top_p,
    )

    return outputs[0]["generated_text"][-1]["content"]

# had to add this to fix a bug if you test remote model, then local, the input to local is no longer acceptable to internal qwen logic
def normalize_history(history):
    normalized = []

    for item in history:
        content = item["content"]

        if isinstance(content, list):
            content = "".join(
                part.get("text", "")
                for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )

        normalized.append({
            "role": item["role"],
            "content": content,
        })

    return normalized

def respond(
    message,
    history: list[dict[str, str]],
    system_message,
    time_required,
    pantry_staples,
    use_local_model,
    hf_token, #this is going to be provided by the user 
 ):
    action = current_overload_action()

    if action == "REJECT_REQUESTS":
        yield "The system is currently at capacity. Please try again in a few minutes."
        return

    effective_max_tokens = REDUCED_MAX_TOKENS if action == "REDUCE_WORKLOAD" else max_tokens
    banner = "The system is operating near capacity; responses may be slower.\n\n" if action == "BANNER" else ""

    messages = [{"role": "system", "content": system_message}]
    messages.extend(normalize_history(history))
    pantry_text = ", ".join(pantry_staples) if pantry_staples else "None selected"
    messages.append(
    {
        "role": "user",
        "content": (
            f"{message}\n\n"
            f"Time Required: {time_required}\n"
            f"Pantry Staples Available: {pantry_text}"
        ),
    }
)

    if use_local_model:
        print("[MODE] local")

        response = local_generate(
            messages,
            effective_max_tokens,
            temperature,
            top_p,
        )

        yield banner + response
        return

    print("[MODE] api")

#user needs to provide their Hugging Face token now to use the API model instead of how we did it for cs1
    if not hf_token:
        yield "⚠️ Please enter your Hugging Face token first."
        return

    client = InferenceClient(
        token=hf_token, #user is providing this now
        model=REMOTE_MODEL,
    )

    response = ""

    for chunk in client.chat_completion(
        messages,
        max_tokens=effective_max_tokens,
        stream=True,
        temperature=temperature,
        top_p=top_p,
    ):
        choices = chunk.choices
        token = ""

        if len(choices) and choices[0].delta.content:
            token = choices[0].delta.content

        response += token
        yield banner + response

#need to validate user's token now
def validate_hf_token(hf_token):
    if not hf_token or not hf_token.strip():
        return "⚠️ Enter a Hugging Face token."

    try:
        account = HfApi(token=hf_token.strip()).whoami()
        username = account.get("name", "unknown user")
        return f"Valid Hugging Face token for **{username}**."
    except Exception:
        return (
            "The token could not be validated. "
        )
    
with gr.Blocks() as demo:

    gr.Markdown(
        "# 🍽️ What's For Dinner?",
        elem_id="app-title",
    )

    gr.Markdown(
        "**Don't know what to make for dinner?  Plan your meals with our chatbot. Select the time you have and input your ingredients or special requests.**",
        elem_id="app-subtitle",
    )

    # Token entry immediately below the header
    with gr.Row():
        hf_token = gr.Textbox(
            label="Hugging Face Token",
            placeholder="hf_...",
            type="password",
            scale=4,
        )

        validate_button = gr.Button(
            "Validate Token",
            scale=1,
        )

    token_status = gr.Markdown()

    time_required = gr.Dropdown(
        choices=["20 minutes", "30 minutes", "1 hour", "2 hours"],
        value=None,
        label="How Much Time Do You Have?",
        elem_id="time-required",
    )

    pantry_staples = gr.CheckboxGroup(
    choices=[
        "Salt",
        "Pepper",
        "Olive Oil",
        "Butter",
        "Garlic",
        "Onions",
        "Peppers",
        "Rice",
        "Pasta",
        "Eggs",
        "Flour",
        "Sugar",
        "Milk",
        "Cheese",
        "Tomatoes",
        "Bread",
        "Vinegar"
    ],
    label="Which Pantry Staples Do You Have?",
    elem_id="pantry-staples",
)
    system_message = gr.Textbox(
        value="You are a recipe assistant Chatbot. Use the user's input ingredients, checked pantry staples, and cooking time to suggest 1 recipe that can be made within the amount of time specified. If you suggest ingredients that the user does not explictly have, list these as optional.",
        label="System message",
        render=False,
    )
    use_local_model = gr.Checkbox(
        label="Use Local Model",
        value=False,
        render=False,
    )

    with gr.Column(elem_id="chat-container"):
        chatbot = gr.ChatInterface(
            fn=respond,
            additional_inputs=[
                system_message,
                time_required,
                pantry_staples,
                use_local_model,
                hf_token
            ],
        )

        gr.Markdown(
            "**Use Additional inputs to switch between the API model and the locally executed model.**",
            elem_id="model-note",
        )

        #adding in validation button based on if user provided token or not for api
        validate_button.click(
            fn=validate_hf_token,
            inputs=hf_token,
            outputs=token_status,
            api_visibility="private",
    )


if __name__ == "__main__":
    demo.launch(
        theme=gr.themes.Soft(),
        css=fancy_css,
        allowed_paths=["cute_kitchen_background.png"],
        server_name = '0.0.0.0', #from Simeon's code, make accessible on local network
        server_port = 7860 #server port for the VM
    )
