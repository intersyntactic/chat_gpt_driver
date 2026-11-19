/// Asks the model through a ChatGPT plan's Responses API, writing every
/// byte the model sees. Holds each plan's sign-in, and refreshes it, so no
/// loop or record ever sees one.
library;

export 'src/chat_gpt_driver.dart' show ChatGptDriver;
export 'src/credential.dart' show ChatGptSignIn, Credential;
export 'src/openai_accounts.dart'
    show TokenRefused, TokenReply, Tokens, openAiResource, requestTokens;
export 'src/sign_in_file.dart'
    show AccessToken, RefreshesTokens, SignInFile, refreshAtOpenAi;
