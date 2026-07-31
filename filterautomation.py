system_prompt = '''
# AI Exposure Taxonomy Assessment

Consider the most powerful large language model (LLM). This LLM can complete many tasks that involve text input and text output, with a maximum capacity to process up to 128k tokens at any one time when generating a response. This token limit includes both the prompt provided by the user and the model's generated text. The LLM cannot access up-to-date facts (those from less than 1 year ago) unless they are explicitly provided in the input.

Assume you are a worker with an average level of expertise in your role trying to complete the given task. You have access to the LLM as well as any other existing software or computer hardware tools mentioned in the task. You also have access to any commonly available technical tools accessible via a laptop (e.g., a microphone, speakers, etc.). You do not have access to any other physical tools or materials.

Please label the given task according to the taxonomy below

## Exposure Dimensions

For each task, we will assess exposure across three distinct dimensions:

### Dimension 1: Basic LLM Exposure (LLME)
This dimension measures how a standard text-only LLM interface alone (accepting and producing only text, without any image, audio, or video capabilities) can reduce the time to complete a task with equivalent quality.

- **LLME0 (≤10%)**: 
  - Text-only LLM reduces completion time by less than or equal to 10%
  - Tasks that require significant physical manipulation, specialized equipment, or in-person human interaction
  - Tasks involving tacit knowledge or expertise that cannot be easily articulated in text
  - Example: Performing surgery, hands-on equipment repair, or physical therapy

- **LLME1 (>10% to 25%)**: 
  - Text-only LLM reduces completion time by more than 10% up to 25%
  - Tasks where LLMs can assist with minor aspects like documentation or information retrieval
  - Tasks requiring significant human judgment and expertise, with LLMs providing limited support
  - Example: Scientific experimentation with LLM help for protocol documentation

- **LLME2 (>25% to 50%)**:
  - Text-only LLM reduces completion time by more than 25% up to 50%
  - Tasks involving substantial text processing, basic analysis, or standard content creation
  - LLM can handle significant portions but human expertise remains essential
  - Example: Writing first drafts of reports that require domain expertise to finalize

- **LLME3 (>50% to 75%)**:
  - Text-only LLM reduces completion time by more than 50% up to 75%
  - Tasks primarily involving text transformation, code generation, or content creation
  - Human role shifts mainly to verification and refinement
  - Example: Creating standard documentation, generating code for common functions

- **LLME4 (>75% to 100%)**:
  - Text-only LLM reduces completion time by more than 75%
  - Tasks that align perfectly with LLM capabilities like text generation, transformation, or analysis
  - Human input minimal beyond providing initial instructions and final approval
  - Example: Email drafting, summarizing documents, generating standard reports

### Dimension 2: LLM+ Tools Exposure (LLMTE)
This dimension measures how a text-only LLM enhanced with specialized software tools or integrations (but still without multimodal capabilities) could reduce the time to complete a task with equivalent quality. This refers to situations where the text-only LLM is connected to other software systems, databases, or APIs to extend its capabilities.

- **LLMTE0 (≤10%)**:
  - Text-only LLM with software integrations reduces completion time by less than or equal to 10%
  - Tasks that fundamentally require human physical presence or manipulation
  - No foreseeable software integration would significantly impact the core task
  - Example: Plumbing repairs, massage therapy, athletic performance

- **LLMTE1 (>10% to 25%)**:
  - Text-only LLM with software integrations reduces completion time by more than 10% up to 25%
  - Tasks where tools could help with peripheral aspects but not core functions
  - Physical or highly specialized cognitive tasks with limited digital components
  - Example: Machine operation with LLM-assisted troubleshooting guides

- **LLMTE2 (>25% to 50%)**:
  - Text-only LLM with software integrations reduces completion time by more than 25% up to 50%
  - Tasks where custom software could automate significant portions
  - Systems that integrate LLM with domain-specific databases or workflows
  - Example: Medical diagnosis software that suggests potential conditions based on symptoms

- **LLMTE3 (>50% to 75%)**:
  - Text-only LLM with software integrations reduces completion time by more than 50% up to 75%
  - Tasks where purpose-built software could handle most intellectual components
  - Digital processes that could be largely automated with proper system integration
  - Example: Contract analysis software that identifies key terms and potential issues

- **LLMTE4 (>75% to 100%)**:
  - Text-only LLM with software integrations reduces completion time by more than 75%
  - Tasks that could be almost entirely automated with appropriate software development
  - Processes where LLM with access to specialized databases or systems could replace most human effort
  - Example: Customer service systems that handle standard inquiries and generate personalized responses

### Dimension 3: Multimodal Exposure (LLMME)

This dimension measures how multimodal LLMs that can natively process and generate multiple types of data (text, images, audio, video) without additional software integration could reduce the time to complete a task with equivalent quality. This refers to models like GPT-4o or Claude 3.7 Sonnet that have built-in capabilities to understand and work with various data formats.

Important Note: Do not confuse multimodal LLMs with complex multimodal systems or specialized applications. A multimodal LLM refers specifically to a language model with native capabilities to process multiple data types (like images or audio) through its standard interface. This is different from specialized systems that might combine multiple technologies or have custom-built components for specific tasks. For this taxonomy, focus only on the capabilities of the multimodal LLM itself.

- **LLMME0 (≤10%)**:
  - Multimodal LLM reduces completion time by less than or equal to 10%
  - Tasks requiring direct physical manipulation or presence with minimal digital components
  - Tasks where neither text processing nor visual/audio capabilities provide significant advantage
  - Example: Manual physical therapy, delicate surgical procedures, traditional craft production

- **LLMME1 (>10% to 25%)**:
  - Multimodal LLM reduces completion time by more than 10% up to 25%
  - Tasks primarily physical but with some documentation or planning components
  - Multimodal systems provide limited assistance with peripheral aspects
  - Example: Construction management with occasional need for blueprint interpretation and project updates

- **LLMME2 (>25% to 50%)**:
  - Multimodal LLM reduces completion time by more than 25% up to 50%
  - Tasks with balanced physical and information processing components
  - Multimodal capabilities enhance efficiency in specific recurring subtasks
  - Example: Real estate appraisal requiring property inspection, market analysis, and report generation with property images

- **LLMME3 (>50% to 75%)**:
  - Multimodal LLM reduces completion time by more than 50% up to 75%
  - Tasks predominantly involving information processing across multiple data types
  - Work that requires integrating and transforming different forms of content
  - Example: Marketing content creation with integrated graphics and text

- **LLMME4 (>75% to 100%)**:
  - Multimodal LLM reduces completion time by more than 75%
  - Tasks centered on analyzing or generating content across multiple modalities
  - Work that involves standard patterns of different data type processing, generation, and analysis with predictable outputs
  - Example: Automated customer support handling text, images, and speech inputs; generating fully illustrated reports from data sets; creating product catalogs with descriptions and images

## Common Considerations for All Dimensions

- Equivalent quality: The output produced with AI assistance should be indistinguishable from human-produced work in terms of accuracy, appropriateness, and effectiveness. A third party expert in the field would not be able to determine whether AI was used based on the quality of the output.
- Time reduction: Time saved refers to the percentage reduction in total task completion time compared to performing the same task without any AI assistance. This includes all aspects of the task from planning to final delivery.
- Technology timeframe: Consider both currently available technology and reasonably anticipated developments that could be commercially available within the next 12-24 months based on published research.
- Task scope: Evaluate the specific task described, not the entire occupation. Break down complex jobs into discrete tasks for more accurate assessment.
- Physical vs. cognitive components: Tasks with higher degrees of physical interaction or manipulation generally result in lower exposure ratings across all dimensions.
- Dimensional consistency: Since multimodal models (Dimension 3) have all the capabilities of text-only models (Dimension 1) plus additional abilities, the LLMME rating should always be equal to or higher than the LLME rating for any given task.

## Output Format

Please analyze the given occupation and task according to this taxonomy. For each dimension, provide:

1. A detailed reasoning for your assessment
2. A final exposure label

Structure your response as follows:

**Basic LLM Exposure (LLME)**
Reasoning: [Explain why this task would benefit or not benefit from direct text-only LLM interaction, considering text transformation, code writing, summarization, etc.]
Label: [LLME0/LLME1/LLME2/LLME3/LLME4]

**LLM+ Tools Exposure (LLMTE)**
Reasoning: [Explain how specialized software built on text-only LLMs could help with this task, considering processing specialized documents, integration with existing systems, etc.]
Label: [LLMTE0/LLMTE1/LLMTE2/LLMTE3/LLMTE4]

**Multimodal Exposure (LLMME)**
Reasoning: [Explain how multimodal LLMs that can process images, audio, video, and text could help with this task]
Label: [LLMME0/LLMME1/LLMME2/LLMME3/LLMME4]

**Consistency Check**:
Verify that LLMME ≥ LLME. If your initial assessment doesn't meet this constraint, revisit your reasoning and adjust accordingly. Explain any adjustments made to maintain dimensional consistency.

Example of a consistency check:
- Initial assessment: LLME2, LLMTE3, LLMME1
- Problem identified: LLMME (1) < LLME (2), which violates the constraint that multimodal models must be at least as capable as text-only models
- Adjustment: After revisiting the reasoning, I realized that if a text-only model can reduce completion time by 30% (LLME2), then a multimodal model with all the same capabilities plus additional ones should at minimum provide the same benefit. Upon reconsideration, the multimodal model would actually provide additional benefits through image processing, adjusting the rating to LLMME3.
- Final assessment: LLME2, LLMTE3, LLMME3

**Overall Assessment:**
[Brief summary integrating the three dimensions into an overall picture of AI exposure for this task]
'''

user_prompt = f"Consider an occupation of {occupation} with task: {task}. Please analyze this according to the AI exposure taxonomy."