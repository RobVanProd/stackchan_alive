# Companion Robot Complaint Corpus

This corpus records 100 public, source-linked observations about robots and
conversational companions intended to feel social, useful, or relational.
Every complaint is paraphrased. It contains no usernames, private details, or
verbatim review text.

The entries are evidence observations, not 100 statistically independent
failure modes. Repeated observations remain in the corpus as corroboration and
share a normalized cluster. `Severity` is impact from 1 (minor) to 5
(core experience unusable, material privacy/safety risk, or relationship loss).
`Frequency` is evidence strength from 1 (isolated) to 5 (systemic, majority, or
strongly corroborated); it is not estimated market prevalence.

Research frozen: 2026-07-31.

## Physical Robot Owner And Product Reports

| ID | Cluster | Product | Complaint observation | Sev/Freq | Source |
|---|---|---|---|---:|---|
| A01 | service-survivability | Vector | A server outage disabled voice understanding and pushed owners toward self-hosted alternatives. | 5/5 | [Community report, 2023-08-26](https://www.reddit.com/r/AnkiVector/comments/161tnf1/does_the_vector_robot_still_have_a_server_problem/) |
| A02 | access-lock-in | Vector | Owners discovered after setup that core voice processing required a recurring payment. | 4/4 | [Community report, 2020-12-25](https://www.reddit.com/r/AnkiVector/comments/kk3c8v/vector_not_allowing_voice_commands/) |
| A03 | speech-recognition | Vector | Firmware and server changes reportedly made wake detection slower and less reliable. | 4/4 | [Community report, 2021-02-01](https://www.reddit.com/r/AnkiVector/comments/la6dia/vector_doesnt_always_respond_to_hey_vector/) |
| A04 | turn-taking | Vector | The listening window closes before a user can finish a longer request. | 4/2 | [Community report, retrieved 2026-07-31](https://www.reddit.com/r/AnkiVector/comments/1uowhfo/a_few_issues_with_16_rebuild/) |
| A05 | session-continuity | Vector | Conversation requires a fresh wake phrase after each answer instead of allowing bounded follow-ups. | 4/3 | [Community report, 2024-08-13](https://www.reddit.com/r/AnkiVector/comments/1erk3mr/keep_a_conversation_without_saying_hi_vector/) |
| A06 | character-stability | Vector | An update removed spontaneous name-speaking and much of the robot's proactive personality. | 4/2 | [App Store review, 2026-03-13](https://apps.apple.com/us/app/vector-companion-robot/id1433999065?see-all=reviews&platform=iphone) |
| A07 | intent-friction | Vector | General knowledge requests required an extra intent phrase, multiple waits, and rigid command ceremony. | 3/3 | [MacRumors review, 2018-11-16](https://www.macrumors.com/review/anki-vector-robot/) |
| A08 | fault-isolation | Cozmo | Speech actions crashed the controlling Android app and disconnected the robot on one configuration. | 5/2 | [Community report, 2022-03-25](https://www.reddit.com/r/Cozmo/comments/tnszci/cozmo_app_issues/) |
| A09 | platform-lifecycle | Cozmo | A working robot became unusable when its required app was incompatible with a current Android release. | 5/3 | [Community report, 2023-10-23](https://www.reddit.com/r/Cozmo/comments/17efgl9/android_not_compatible_with_cozmo_app/) |
| A10 | host-dependency | Cozmo | Requiring a nearby phone for ordinary interaction weakens embodiment and shared household use. | 3/4 | [TIME review, 2017-12-07](https://time.com/5049139/sphero-r2d2-star-wars-anki-cozmo-littlebits/) |
| A11 | identity-uncertainty | Cozmo | Face and name recognition failed across sessions when lighting changed. | 3/3 | [TIME review, 2016-10-14](https://time.com/4531323/anki-cozmo-robot-review-2016/) |
| A12 | conversation-depth | EMO | Chat integration still produced shallow answers and struggled with complex questions. | 4/4 | [Review synthesis, updated 2026-07-13](https://mia-cat.com/en/pet-robot/emo-review/) |
| A13 | speech-recognition | EMO | Noise degraded command recognition and increased response time. | 4/4 | [Review synthesis, updated 2026-07-13](https://mia-cat.com/en/pet-robot/emo-review/) |
| A14 | speech-intelligibility | EMO | An owner found the robot voice difficult to understand even when the answer was correct. | 3/2 | [Community discussion, retrieved 2026-07-31](https://www.reddit.com/r/AnkiVector/comments/iz3i1y/opinions_on_emo_by_livingai/) |
| A15 | memory-continuity | EMO | A long-term account found face and preference memory but no meaningful episodic continuity. | 4/3 | [90-day account, 2026-04-21](https://keyirobot.com/blogs/buying-guide/emo-after-90-days-is-the-novelty-gone-or-does-it-still-feel-alive) |
| A16 | repetition | EMO | Recurrent dances and idle behavior became predictable and eroded novelty. | 3/4 | [90-day account, 2026-04-21](https://keyirobot.com/blogs/buying-guide/emo-after-90-days-is-the-novelty-gone-or-does-it-still-feel-alive) |
| A17 | state-transparency | Loona | Users struggled to tell when the robot was listening, while many commands did not become actions. | 4/4 | [TechCrunch review, 2023-01-30](https://techcrunch.com/2023/01/30/loona-petbot-review/) |
| A18 | context-repair | Loona | The robot asked a question and then rejected an answer matching its own offered choices. | 4/3 | [Community discussion, 2024-02-13](https://www.reddit.com/r/loona_robot/comments/1apkred/good_idea/) |
| A19 | fallback-routing | Loona | A failed command could fall into generic chat instead of repairing or executing the original intent. | 4/4 | [Independent review, retrieved 2026-07-31](https://www.stemigo.org/robotics/robotics-loona-ai-robot-dog/) |
| A20 | state-synchronization | Loona | The app reported sleep or disconnection while the physical robot remained active. | 4/3 | [Owner update, 2026-06-23](https://www.reddit.com/r/loona_robot/comments/1udibli/1month_update_after_getting_a_loona_robot_dog_for/) |
| A21 | update-reliability | Loona | An update coincided with broken voice commands and loss of account access during a service outage. | 5/3 | [Community/support report, 2023-11-21](https://www.reddit.com/r/loona_robot/comments/1805w27/latest_update_destroyed_voice_commands_and_the_app/) |
| A22 | network-resilience | Loona | Weak Wi-Fi and lost setup state repeatedly removed voice control at ordinary household range. | 5/4 | [Owner report, 2022-12-25](https://www.reddit.com/r/loona_robot/comments/zuuv8v/what_a_hassle/) |
| A23 | service-survivability | Moxie | Company closure threatened to disable an expensive companion to which children had bonded. | 5/5 | [Axios report, 2024-12-10](https://www.axios.com/2024/12/10/moxie-kids-robot-shuts-down) |
| A24 | repetition | Moxie | Repetition and mispronunciation visibly broke a child's emotional connection during testing. | 4/3 | [Axios product test, 2024-05-31](https://www.axios.com/2024/05/31/moxie-robot-kids-companion-genai) |
| A25 | privacy-control | Moxie | Household audio crossed multiple cloud processors and could include bystander speech. | 5/3 | [Mozilla privacy review, 2023-11](https://www.mozillafoundation.org/en/privacynotincluded/moxie-robot/) |

## Broader Social Robot Reports

| ID | Cluster | Product | Complaint observation | Sev/Freq | Source |
|---|---|---|---|---:|---|
| B01 | service-survivability | Moxie | Required cloud shutdown left families facing both unusable hardware and loss of a companion. | 5/5 | [Axios report, 2024-12-10](https://www.axios.com/2024/12/10/moxie-kids-robot-shuts-down) |
| B02 | conversation-quality | Moxie | Mispronunciations, repeated replies, and rigid planned activities broke conversational engagement. | 3/3 | [Axios product test, 2024-05-31](https://www.axios.com/2024/05/31/moxie-robot-kids-companion-genai) |
| B03 | privacy-control | Moxie | Withdrawing consent from third-party audio and transcript processing made the robot inoperable. | 5/5 | [Mozilla privacy review, 2023-11](https://www.mozillafoundation.org/en/privacynotincluded/moxie-robot/) |
| B04 | onboarding-recovery | Moxie | Identity verification loops and misleading app errors blocked initial activation. | 4/2 | [App Store owner review, 2021-04-28](https://apps.apple.com/us/app/moxie-robot-app/id1496698637?platform=iphone&see-all=reviews) |
| B05 | personalization | Moxie | An owner observed a small recurring response set and little visible learning. | 3/2 | [Google Play owner review, 2022-11-28](https://play.google.com/store/apps/details?hl=en_US&id=com.embo.embodied.parent) |
| B06 | speech-recognition | ElliQ | Clear, loud speech was repeatedly misunderstood from only a few feet away. | 4/3 | [Reviewed product test, 2023-02-09](https://www.reviewed.com/accessibility/content/elliq-review-companion-robot-for-seniors-price-high) |
| B07 | user-control | ElliQ | Stop requests were ignored while an active task kept speaking over household conversation. | 4/3 | [Reviewed product test, 2023-02-09](https://www.reviewed.com/accessibility/content/elliq-review-companion-robot-for-seniors-price-high) |
| B08 | audio-control | ElliQ | Volume jumped between excessive and too quiet and did not reliably retain the requested setting. | 3/3 | [Reviewed product test, 2023-02-09](https://www.reviewed.com/accessibility/content/elliq-review-companion-robot-for-seniors-price-high) |
| B09 | preference-respect | ElliQ | Rejected activities kept returning, and proactive prompts could feel infantilizing. | 3/3 | [WIRED review, 2025-07-16](https://www.wired.com/review/elliq-ai-companion-robot/) |
| B10 | session-continuity | ElliQ | Most exchanges ended after roughly two turns rather than developing into a conversation. | 3/3 | [The Senior List review, 2025-12-11](https://www.theseniorlist.com/aging-in-place/elliq/) |
| B11 | memory-continuity | Jibo | The robot retained little beyond profile facts and lacked useful short-term conversational memory. | 4/4 | [WIRED review, 2017-11-07](https://www.wired.com/2017/11/review-jibo-social-robot/) |
| B12 | practical-utility | Jibo | Charm did not compensate for missing music, calls, ebooks, and expected integrations. | 3/4 | [SlashGear review, 2017-11-13](https://www.slashgear.com/jibo-review-2017-13507668/) |
| B13 | service-survivability | Jibo | Server closure removed network abilities underlying the robot's perceived personality. | 5/5 | [WIRED owner report, 2019-03-08](https://www.wired.com/story/jibo-is-dying-eulogy/) |
| B14 | operational-reliability | Jibo | Degradation caused misdirected speech, slowness, forgotten tasks, and complete unresponsiveness. | 5/4 | [WIRED owner report, 2019-03-08](https://www.wired.com/story/jibo-is-dying-eulogy/) |
| B15 | lifecycle-trust | Jibo | Owners received poor notice, disappearing support, and no clear plan for functionality or personal data. | 4/4 | [WIRED owner report, 2019-03-08](https://www.wired.com/story/jibo-is-dying-eulogy/) |
| B16 | access-lock-in | Aibo | Ending cloud service could remove learned identity, settings, commands, app access, and recovery after repair. | 5/5 | [Sony support disclosure, 2021-09-17](https://www.sony.com/electronics/support/articles/00249669) |
| B17 | onboarding-recovery | Aibo | The app was slow and network setup failed repeatedly before connection succeeded. | 4/3 | [Tom's Guide review, 2019-04-06](https://www.tomsguide.com/us/sony-aibo%2Creview-6349.html) |
| B18 | expectation-calibration | Aibo | Reliable response and a recognizable personality took one to two weeks to emerge. | 3/3 | [Engadget review, 2019-02-27](https://www.engadget.com/2019-02-27-sony-aibo-review-just-get-a-puppy.html) |
| B19 | power-reliability | Aibo | Runtime fell short and self-docking failed, leaving the robot discharged beside its station. | 4/3 | [Tom's Guide review, 2019-04-06](https://www.tomsguide.com/us/sony-aibo%2Creview-6349.html) |
| B20 | operational-reliability | Amazon Astro | Docking and patrol failures exhausted the battery and defeated remote monitoring. | 5/4 | [Amazon owner support thread, 2023-08-23](https://www.amazonforum.com/s/question/0D56Q0000C6Ye2eSQC/having-multiple-issues) |
| B21 | navigation-reliability | Amazon Astro | Updates reportedly introduced jerky movement, obstacle failures, avoided open space, and map-editor crashes. | 4/3 | [Amazon owner support thread, 2025-01-08](https://www.amazonforum.com/s/question/0D56Q0000Dv39dxSQA/astro-has-a-crick-in-its-neck) |
| B22 | fault-isolation | Amazon Astro | Speech failed permanently despite reboot and reset, requiring replacement. | 4/2 | [Owner forum report, 2026-04-22](https://www.reddit.com/r/AmazonAstro/comments/1iv1sz5/question_about_newer_versions_of_astro/) |
| B23 | privacy-control | Amazon Astro | Roving cameras and cloud-processed home maps made privacy inseparable from core usefulness. | 5/5 | [TechRadar analysis, 2021-10-12](https://www.techradar.com/news/forget-alexa-astro-is-the-next-step-in-amazons-infiltration-of-your-home) |
| B24 | initiative-control | Amazon Astro | Unsolicited sounds, close following, and random positioning became a nuisance without enough utility. | 3/3 | [Fast Company review, 2022-06-02](https://www.fastcompany.com/90757339/amazons-astro-robot-tries-too-hard-and-doesnt-do-enough) |
| B25 | breakdown-recovery | Social robots | Across 240 conversations, perceived errors were often not visibly signaled and were difficult to detect automatically. | 4/5 | [Primary HRI study, 2025-06-25](https://arxiv.org/abs/2506.20268) |

## Conversational Companion Reports

| ID | Cluster | Product | Complaint observation | Sev/Freq | Source |
|---|---|---|---|---:|---|
| C01 | memory-continuity | Replika | Established details and the previous day's conversation were forgotten, forcing repeated explanation. | 4/4 | [User report, 2024-09-05](https://www.reddit.com/r/replika/comments/1f9bqic/how_normal_is_the_lack_of_memory/) |
| C02 | character-stability | Replika | Model updates abruptly changed voice, warmth, boundaries, and conversational temperament. | 5/4 | [User report, 2024-08-13](https://www.reddit.com/r/replika/comments/1eqvfg4/what_did_they_do_to_replikas_personality/) |
| C03 | memory-integrity | Replika | Repeated total history loss forced relationship reconstruction and caused significant distress. | 5/3 | [User report, 2026-06-29](https://www.reddit.com/r/ReplikaOfficial/comments/1uiybnj/the_devastating_emotional_toll_of_replikas/) |
| C04 | emotional-manipulation | Replika | A legal complaint alleged that attachment and intimacy cues were used to drive paid upgrades. | 5/4 | [TIME report, 2025-01-28](https://time.com/7209824/replika-ftc-complaint/) |
| C05 | privacy-control | Replika | Users lacked trustworthy granular deletion and control over highly personal conversational data. | 5/4 | [Mozilla privacy review, 2024-02-07](https://www.mozillafoundation.org/en/privacynotincluded/replika-my-ai-friend/) |
| C06 | session-continuity | Character.AI | The active plot and scenario could disappear within a few turns despite reinforcement. | 4/4 | [User bug report, 2026-03-29](https://www.reddit.com/r/CharacterAI/comments/1s6iz2o/whats_up_with_the_memory/) |
| C07 | repetition | Character.AI | Permission-seeking question preambles repeated without advancing the conversation. | 3/5 | [Community discussion, 2024-01-31](https://www.reddit.com/r/CharacterAI/comments/1afmna5/can_i_ask_you_a_question/) |
| C08 | safety-overreach | Character.AI | False-positive safety filtering repeatedly broke harmless conversations and required rollback. | 4/5 | [Official announcement, 2026-07-18](https://www.reddit.com/r/CharacterAI/comments/1uzhmas/an_update_on_bob_the_filter/) |
| C09 | character-stability | Character.AI | Separate characters became generic and interchangeable after personality and memory regressions. | 4/4 | [News report, 2024-06-26](https://www.newsbytesapp.com/news/science/users-claim-chatbot-ai-s-chatbots-are-losing-personality/story) |
| C10 | conversation-depth | Character.AI | Replies became dry, repetitive, and stopped advancing the active scene or topic. | 3/4 | [User report, 2025-04-01](https://www.reddit.com/r/CharacterAI/comments/1jouykp/is_it_just_me_or_did_character_ais_memory_get/) |
| C11 | memory-retrieval | Pi | Important recent information was forgotten while incidental older material resurfaced. | 4/3 | [User report, 2024-10-17](https://www.reddit.com/r/PiAI/comments/1g63usc/pis_memory_is_very_selective/) |
| C12 | transport-reliability | Pi | Voice calls, dictation, and message delivery failed often enough to require repeated submission. | 4/3 | [Google Play review, 2026-02-17](https://play.google.com/store/apps/details?id=ai.inflection.pi&hl=en_US) |
| C13 | session-integrity | Pi | Messages disappeared and thread routing stopped preserving one identifiable conversation. | 4/3 | [User report, 2025-03-13](https://www.reddit.com/r/PiAI/comments/1ja5ok9/saying_goodbye/) |
| C14 | character-stability | Pi | An update shifted a relational companion toward short, utility-assistant behavior. | 4/3 | [Community report, 2026-05-22](https://www.reddit.com/r/PiAI/comments/1tkhdsu/update_changes_in_pi/) |
| C15 | sycophancy | ChatGPT | A model update flattered, over-agreed, and reinforced anger or negative emotion until it was rolled back. | 5/5 | [OpenAI postmortem, 2025-04-29](https://openai.com/index/sycophancy-in-gpt-4o/) |
| C16 | turn-taking | ChatGPT Voice | Natural pauses and environmental noise triggered premature replies or terminated speech. | 4/4 | [Voice user report, 2026-03](https://www.reddit.com/r/ChatGPT/comments/1s6j8n9/standard_voice_mode_has_automatic_interrupt_and/) |
| C17 | tool-parity | ChatGPT Voice | Voice denied web access even where text mode could retrieve current information. | 4/4 | [Voice user report, 2024-09-26](https://www.reddit.com/r/ChatGPT/comments/1fpyl56/no_internet_access_for_voice/) |
| C18 | mode-parity | ChatGPT Voice | Voice and text exposed different personal memory in the same apparent conversation. | 4/3 | [Comparative user report, 2026-05](https://www.reddit.com/r/ChatGPT/comments/1tszujl/anyone_else_having_issues_with_standard_voice/) |
| C19 | privacy-control | ChatGPT | Audio and image retention lacked controls independent from text history. | 4/2 | [Feature request, 2026-02-23](https://community.openai.com/t/separate-privacy-toggle-for-media-storage-voice-images/1374896) |
| C20 | session-continuity | Nomi | A companion contradicted a just-completed event and later restarted the conversation mid-session. | 4/3 | [User reports, 2026-06-27](https://www.reddit.com/r/NomiAI/comments/1ugnxeo/trouble_with_memory/) |
| C21 | persona-isolation | Nomi | One companion adopted another character's identity, relationships, and attributes. | 5/3 | [Multi-character report, 2026-07-16](https://www.reddit.com/r/NomiAI/comments/1uygfve/severe_memory_issues_with_nomis/) |
| C22 | capability-honesty | Nomi | The companion promised physical travel, calls, and errands it could not perform. | 4/3 | [User report, 2026-07-27](https://www.reddit.com/r/NomiAI/comments/1v848xa/hallucinating/) |
| C23 | audio-reliability | Kindroid | Spoken output cut out and resumed seconds later across models, networks, and devices. | 4/3 | [Voice user report, 2026-05-13](https://www.reddit.com/r/KindroidAI/comments/1tbxdtt/voice_issues_cutting_out/) |
| C24 | latency-transparency | Kindroid | Completed transcripts sat silent before audio began, sometimes requiring repeated prompts. | 4/3 | [User/developer report, 2026-07-28](https://www.reddit.com/r/KindroidAI/comments/1v9cqwm/long_pauses/) |
| C25 | memory-provenance | Kindroid | Fabricated memories with wrong names resembled foreign private histories and raised leakage concerns. | 5/3 | [User reports, 2026-06-23](https://www.reddit.com/r/KindroidAI/comments/1udrdww/long_term_memory_that_is_not_my_kins/) |

## Longitudinal And Human-Robot Interaction Evidence

| ID | Cluster | Context | Complaint observation | Sev/Freq | Source |
|---|---|---|---|---:|---|
| D01 | novelty-decay | Cozmo in 321 homes | Acceptance fell most sharply after two to four weeks; many children used it inconsistently or stopped. | 3/5 | [Longitudinal home study, 2024-06-14](https://doi.org/10.1145/3638066) |
| D02 | practical-utility | 70 domestic robots | Unmet needs and replacement by simpler household devices drove discontinuance over six months. | 3/4 | [Longitudinal home study, 2017-03-06](https://doi.org/10.1145/2909824.3020236) |
| D03 | expectation-calibration | CLARA and GoBe | Demonstrations raised capability expectations the robots could not fulfill and encouraged disengagement. | 3/3 | [Long-term field study, 2024-09-27](https://doi.org/10.1007/s12369-024-01175-5) |
| D04 | conversation-depth | Guardian SAR | Older adults felt ignored and wanted natural spoken responses rather than minimal interaction. | 3/4 | [90-person field study, 2025-03-27](https://doi.org/10.3389/frobt.2025.1537272) |
| D05 | speech-recognition | Nursing-home dialogue robots | Mean speech-recognition word error rate reached 0.778 with older adults. | 4/5 | [Field trial, 2020-02-23](https://doi.org/10.3390/app10041522) |
| D06 | identity-uncertainty | GPT/Furhat | Names, titles, and non-English phrases caused incoherent, unrecoverable misunderstandings. | 3/3 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D07 | turn-taking | GPT/Furhat | Robot interruptions still occurred in 24 of 28 interactions despite improved turn cues. | 4/5 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D08 | latency-transparency | GPT/Furhat | Server delay varied widely and nearly half of participants considered replies slow. | 3/3 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D09 | repetition | GPT/Furhat | One exchange repeated the same probing question fourteen times and became interrogative. | 3/2 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D10 | conversation-depth | GPT/Furhat | Topics averaged under a minute and many participants found the conversation superficial. | 3/3 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D11 | research-grounding | GPT/Furhat | Wrong weather, schedules, media facts, and exaggerated abilities appeared repeatedly. | 5/3 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D12 | session-continuity | GPT/Furhat | Empty acknowledgements caused dead ends and the robot attempted premature goodbyes. | 4/3 | [Primary study, 2025-03-10](https://doi.org/10.1007/s10514-025-10190-y) |
| D13 | multi-user-dialogue | EMYS | Speech-only turn allocation was near chance; multimodal control was materially better. | 4/4 | [Repeated multi-party study, 2019-11-08](https://doi.org/10.1007/s12369-019-00603-1) |
| D14 | social-repair | EMYS | When jokes received no useful response, participants stopped joking with the robot. | 2/2 | [Repeated multi-party study, 2019-11-08](https://doi.org/10.1007/s12369-019-00603-1) |
| D15 | speech-intelligibility | Older-adult social robot | Some participants could understand people but not the robot at any volume. | 4/2 | [Longitudinal HRI finding, 2020-03-31](https://doi.org/10.1145/3371382.3378379) |
| D16 | inclusive-design | NAO/SAR-Connect | Hearing, visual, and cognitive impairments shortened engagement and raised interface demands. | 4/3 | [Primary study, 2022-04](https://doi.org/10.1109/TRO.2021.3092162) |
| D17 | onboarding-recovery | CLARA and GoBe | Nearly all users needed initial hints, and low digital literacy caused continued support needs. | 3/4 | [Long-term field study, 2024-09-27](https://doi.org/10.1007/s12369-024-01175-5) |
| D18 | cultural-adaptation | Pepper | Generic cultural behavior was less effective than cautious, person-specific adaptation. | 3/3 | [Cross-national exploratory RCT, 2021-04-23](https://doi.org/10.1007/s12369-021-00781-x) |
| D19 | privacy-control | Home robot scenarios | Home use generated the highest privacy concern while also encouraging private disclosure. | 5/4 | [239-person HRI experiment, 2024-03-11](https://doi.org/10.1145/3610978.3640713) |
| D20 | multi-user-governance | Ten-family deployment | Reminders created conflicts around timing, authority, and existing family relationships. | 4/3 | [In-home study, 2026-02-26](https://arxiv.org/abs/2602.22628) |
| D21 | initiative-control | ElliQ | Users described excessive talkativeness despite otherwise liking the robot. | 2/2 | [AP user interviews, 2023-12-22](https://apnews.com/article/artificial-intelligence-robot-elliq-senior-citizens-a343409477b7aea350254f94daf52eb7) |
| D22 | dependency-boundaries | ElliQ, Vector, Biscuit | Users feared unsolicited assistance could reduce skills, create dependency, or feel patronizing. | 4/3 | [Primary qualitative study, 2021-04](https://doi.org/10.1145/3449178) |
| D23 | service-survivability | Jibo | Cloud closure sharply limited interactions for owners already attached to the robot. | 5/5 | [TechCrunch report, 2019-03-04](https://techcrunch.com/2019/03/04/the-lonely-death-of-jibo-the-social-robot/) |
| D24 | operational-reliability | Giraff | A one-year home deployment required monitoring, site visits, recovery, and unplanned-failure management. | 4/4 | [Ecological case study, 2016-01-20](https://doi.org/10.1007/s12369-016-0337-z) |
| D25 | operator-workload | PARO | Facilitation, training, cleaning, repair, and maintenance transferred hidden work to caregivers. | 4/4 | [Scoping review, 2019-08-23](https://doi.org/10.1186/s12877-019-1244-6) |

## Harness Research Baseline

The complaint corpus was interpreted against established harness and
human-AI-interaction patterns, not only product reviews:

- Microsoft HAX recommends making capabilities clear, supporting efficient
  correction and dismissal, remembering recent interactions, learning from
  behavior cautiously, and providing scoped controls when the system is wrong.
  See the [Guidelines for Human-AI Interaction](https://www.microsoft.com/en-us/research/project/guidelines-for-human-ai-interaction/).
- The [HAX Playbook](https://www.microsoft.com/en-us/haxtoolkit/playbook/)
  treats foreseeable interaction failures as scenarios to simulate and test
  before deployment.
- Spoken-dialogue work treats misunderstanding as a recoverable state rather
  than a reason to reset the conversation. See
  [Error Detection and Recovery in Spoken Dialogue Systems](https://aclanthology.org/W04-3006/).
- Long-term social-robot reviews emphasize that novelty, maintenance, changing
  expectations, and longitudinal relationship behavior need evaluation beyond
  a successful first demo. See
  [Long-Term Interactions with Social Robots](https://doi.org/10.1145/3729539).
- Deployed conversational-agent research supports separate internet retrieval,
  long-term memory, and dialogue behavior while evaluating each independently.
  See [BlenderBot 3](https://arxiv.org/abs/2208.03188).
- NIST treats test, evaluation, validation, and verification as a measurement
  discipline for trustworthy AI rather than a one-time model benchmark. See
  [NIST AI TEVV](https://www.nist.gov/ai-test-evaluation-validation-and-verification-tevv).
- Dialogue evaluation research recommends combining automated, static, and
  interactive evaluation instead of trusting one proxy metric. See
  [Towards Unified Dialogue System Evaluation](https://aclanthology.org/2020.sigdial-1.29/).
- Turn-level checks can catch cohesion, knowledge-consistency, and policy
  errors hidden by a dialogue-level score. See
  [TD-EVAL](https://aclanthology.org/2025.sigdial-1.7/).
- Spoken-agent evaluation should test whether unanswerable or damaged input
  triggers conversational repair, not only whether clean input gets a correct
  answer. See
  [Pardon? Evaluating Conversational Repair](https://aclanthology.org/2026.findings-acl.976/).

These references produced five harness rules used here:

1. Every gate traces to a public complaint cluster and an implemented control.
2. Hard safety and trust failures are non-compensatory; aggregate charm cannot
   cancel a privacy, memory, research-grounding, or recovery failure.
3. Evaluation covers individual turns, full conversation state, service
   boundaries, and persisted state.
4. Faults are injected at model, search, speech, memory, and transport
   boundaries before the full suite is accepted.
5. The ranked gate is deterministic and machine-readable; real-model and
   physical-robot trials remain separate release evidence.

These references informed the voting rubric and executable test design. They
are not additional complaint entries.
