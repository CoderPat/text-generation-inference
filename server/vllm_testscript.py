# Tests if VLLM works correctly
import vllm
import time

prompts = [
    'Hello, my name is',
    'CMU\'s PhD students are',
]
sampling_params = vllm.SamplingParams(temperature=0.8, top_p=0.95)

llm = vllm.LLM(model="openlm-research/open_llama_3b_v2")

# time the generation
start = time.time()
outputs = llm.generate(prompts, sampling_params)
end = time.time()
for output in outputs:
    prompt = output.prompt
    generated = output.outputs[0].text
    print(f'Prompt: {prompt!r}, Generated: {generated!r}')
print()
print(f'Time taken: {end - start:.2f}s')