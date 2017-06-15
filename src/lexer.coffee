# The CoffeeScript Lexer. Uses a series of token-matching regexes to attempt
# matches against the beginning of the source code. When a match is found,
# a token is produced, we consume the match, and start again. Tokens are in the
# form:
#
#     [tag, value, locationData]
#
# where locationData is {first_line, first_column, last_line, last_column}, which is a
# format that can be fed directly into [Jison](https://github.com/zaach/jison).  These
# are read by jison in the `parser.lexer` function defined in coffeescript.coffee.

{Rewriter, INVERSES} = require './rewriter'

# Import the helpers we need.
{count, starts, compact, repeat, invertLiterate, merge,
locationDataToString, throwSyntaxError} = require './helpers'

# The Lexer Class
# ---------------

# The Lexer class reads a stream of CoffeeScript and divvies it up into tagged
# tokens. Some potential ambiguity in the grammar has been avoided by
# pushing some extra smarts into the Lexer.
exports.Lexer = class Lexer

  # **tokenize** is the Lexer's main method. Scan by attempting to match tokens
  # one at a time, using a regular expression anchored at the start of the
  # remaining code, or a custom recursive token-matching method
  # (for interpolations). When the next token has been recorded, we move forward
  # within the code past the token, and begin again.
  #
  # Each tokenizing method is responsible for returning the number of characters
  # it has consumed.
  #
  # Before returning the token stream, run it through the [Rewriter](rewriter.html).
  tokenize: (code, opts = {}) ->
    @literate   = opts.literate  # Are we lexing literate CoffeeScript?
    @indent     = opts.initialIndent ? 0 # The current indentation level.
    @baseIndent = opts.initialIndent ? 0 # The overall minimum indentation level
    @indebt     = 0              # The over-indentation at the current level.
    @outdebt    = 0              # The under-outdentation at the current level.
    @indents    = []             # The stack of all current indentation levels.
    @indentLiteral = ''          # The indentation
    @ends       = []             # The stack for pairing up tokens.
    @tokens     = []             # Stream of parsed tokens in the form `['TYPE', value, location data]`.
    @seenFor    = no             # Used to recognize FORIN, FOROF and FORFROM tokens.
    @seenImport = no             # Used to recognize IMPORT FROM? AS? tokens.
    @seenExport = no             # Used to recognize EXPORT FROM? AS? tokens.
    @importSpecifierList = no    # Used to identify when in an IMPORT {...} FROM? ...
    @exportSpecifierList = no    # Used to identify when in an EXPORT {...} FROM? ...

    @chunkLine =
      opts.line or 0             # The start line for the current @chunk.
    @chunkColumn =
      opts.column or 0           # The start column of the current @chunk.
    code = @clean code           # The stripped, cleaned original source code.

    # At every position, run through this list of attempted matches,
    # short-circuiting if any of them succeed. Their order determines precedence:
    # `@literalToken` is the fallback catch-all.
    i = 0
    while @chunk = code[i..]
      consumed = \
           @jsxToken() or
           @identifierToken() or
           @commentToken()    or
           @whitespaceToken() or
           @lineToken()       or
           @stringToken()     or
           @numberToken()     or
           @regexToken()      or
           @jsToken()         or
           @literalToken()

      # Update position
      [@chunkLine, @chunkColumn] = @getLineAndColumnFromChunk consumed

      i += consumed

      return {@tokens, index: i} if opts.untilBalanced and @ends.length is 0

    @closeIndentation()
    @error "missing #{end.tag}", end.origin[2] if end = @ends.pop()
    return @tokens if opts.rewrite is off
    (new Rewriter).rewrite @tokens

  # Preprocess the code to remove leading and trailing whitespace, carriage
  # returns, etc. If we’re lexing literate CoffeeScript, strip external Markdown
  # by removing all lines that aren’t indented by at least four spaces or a tab.
  clean: (code) ->
    code = code.slice(1) if code.charCodeAt(0) is BOM
    code = code.replace(/\r/g, '').replace TRAILING_SPACES, ''
    if WHITESPACE.test code
      code = "\n#{code}"
      @chunkLine--
    code = invertLiterate code if @literate
    code

  # Tokenizers
  # ----------

  # Matches identifying literals: variables, keywords, method names, etc.
  # Check to ensure that JavaScript reserved words aren’t being used as
  # identifiers. Because CoffeeScript reserves a handful of keywords that are
  # allowed in JavaScript, we’re careful not to tag them as keywords when
  # referenced as property names here, so you can still do `jQuery.is()` even
  # though `is` means `===` otherwise.
  identifierToken: ->
    return 0 unless match = IDENTIFIER.exec @chunk
    [input, id, colon] = match

    # Preserve length of id for location data
    idLength = id.length
    poppedToken = undefined

    if id is 'own' and @tag() is 'FOR'
      @token 'OWN', id
      return id.length
    if id is 'from' and @tag() is 'YIELD'
      @token 'FROM', id
      return id.length
    if id is 'as' and @seenImport
      if @value() is '*'
        @tokens[@tokens.length - 1][0] = 'IMPORT_ALL'
      else if @value() in COFFEE_KEYWORDS
        @tokens[@tokens.length - 1][0] = 'IDENTIFIER'
      if @tag() in ['DEFAULT', 'IMPORT_ALL', 'IDENTIFIER']
        @token 'AS', id
        return id.length
    if id is 'as' and @seenExport and @tag() in ['IDENTIFIER', 'DEFAULT']
      @token 'AS', id
      return id.length
    if id is 'default' and @seenExport and @tag() in ['EXPORT', 'AS']
      @token 'DEFAULT', id
      return id.length

    prev = @prev()

    tag =
      if colon or prev? and
         (prev[0] in ['.', '?.', '::', '?::'] or
         not prev.spaced and prev[0] is '@')
        'PROPERTY'
      else
        'IDENTIFIER'

    if tag is 'IDENTIFIER' and (id in JS_KEYWORDS or id in COFFEE_KEYWORDS) and
       not (@exportSpecifierList and id in COFFEE_KEYWORDS)
      tag = id.toUpperCase()
      if tag is 'WHEN' and @tag() in LINE_BREAK
        tag = 'LEADING_WHEN'
      else if tag is 'FOR'
        @seenFor = yes
      else if tag is 'UNLESS'
        tag = 'IF'
      else if tag is 'IMPORT'
        @seenImport = yes
      else if tag is 'EXPORT'
        @seenExport = yes
      else if tag in UNARY
        tag = 'UNARY'
      else if tag in RELATION
        if tag isnt 'INSTANCEOF' and @seenFor
          tag = 'FOR' + tag
          @seenFor = no
        else
          tag = 'RELATION'
          if @value() is '!'
            poppedToken = @tokens.pop()
            id = '!' + id
    else if tag is 'IDENTIFIER' and @seenFor and id is 'from' and
       isForFrom(prev)
      tag = 'FORFROM'
      @seenFor = no
    # Throw an error on attempts to use `get` or `set` as keywords, or
    # what CoffeeScript would normally interpret as calls to functions named
    # `get` or `set`, i.e. `get({foo: function () {}})`.
    else if tag is 'PROPERTY' and prev
      if prev.spaced and prev[0] in CALLABLE and /^[gs]et$/.test(prev[1])
        @error "'#{prev[1]}' cannot be used as a keyword, or as a function call without parentheses", prev[2]
      else
        prevprev = @tokens[@tokens.length - 2]
        if prev[0] in ['@', 'THIS'] and prevprev and prevprev.spaced and /^[gs]et$/.test(prevprev[1]) and
        @tokens[@tokens.length - 3][0] isnt '.'
          @error "'#{prevprev[1]}' cannot be used as a keyword, or as a function call without parentheses", prevprev[2]

    if tag is 'IDENTIFIER' and id in RESERVED
      @error "reserved word '#{id}'", length: id.length

    unless tag is 'PROPERTY'
      if id in COFFEE_ALIASES
        alias = id
        id = COFFEE_ALIAS_MAP[id]
      tag = switch id
        when '!'                 then 'UNARY'
        when '==', '!='          then 'COMPARE'
        when 'true', 'false'     then 'BOOL'
        when 'break', 'continue', \
             'debugger'          then 'STATEMENT'
        when '&&', '||'          then id
        else  tag

    tagToken = @token tag, id, 0, idLength
    tagToken.origin = [tag, alias, tagToken[2]] if alias
    if poppedToken
      [tagToken[2].first_line, tagToken[2].first_column] =
        [poppedToken[2].first_line, poppedToken[2].first_column]
    if colon
      colonOffset = input.lastIndexOf ':'
      @token ':', ':', colonOffset, colon.length

    input.length

  # Matches numbers, including decimals, hex, and exponential notation.
  # Be careful not to interfere with ranges in progress.
  numberToken: ->
    return 0 unless match = NUMBER.exec @chunk

    number = match[0]
    lexedLength = number.length

    switch
      when /^0[BOX]/.test number
        @error "radix prefix in '#{number}' must be lowercase", offset: 1
      when /^(?!0x).*E/.test number
        @error "exponential notation in '#{number}' must be indicated with a lowercase 'e'",
          offset: number.indexOf('E')
      when /^0\d*[89]/.test number
        @error "decimal literal '#{number}' must not be prefixed with '0'", length: lexedLength
      when /^0\d+/.test number
        @error "octal literal '#{number}' must be prefixed with '0o'", length: lexedLength

    base = switch number.charAt 1
      when 'b' then 2
      when 'o' then 8
      when 'x' then 16
      else null

    numberValue = if base? then parseInt(number[2..], base) else parseFloat(number)

    tag = if numberValue is Infinity then 'INFINITY' else 'NUMBER'
    @token tag, number, 0, lexedLength
    lexedLength

  # Matches strings, including multiline strings, as well as heredocs, with or without
  # interpolation.
  stringToken: ->
    [quote] = STRING_START.exec(@chunk) || []
    return 0 unless quote

    # If the preceding token is `from` and this is an import or export statement,
    # properly tag the `from`.
    prev = @prev()
    if prev and @value() is 'from' and (@seenImport or @seenExport)
      prev[0] = 'FROM'

    regex = switch quote
      when "'"   then STRING_SINGLE
      when '"'   then STRING_DOUBLE
      when "'''" then HEREDOC_SINGLE
      when '"""' then HEREDOC_DOUBLE
    heredoc = quote.length is 3

    {tokens, index: end} = @matchWithInterpolations regex, quote
    $ = tokens.length - 1

    delimiter = quote.charAt(0)
    if heredoc
      # Find the smallest indentation. It will be removed from all lines later.
      indent = null
      doc = (token[1] for token, i in tokens when token[0] is 'NEOSTRING').join '#{}'
      while match = HEREDOC_INDENT.exec doc
        attempt = match[1]
        indent = attempt if indent is null or 0 < attempt.length < indent.length
      indentRegex = /// \n#{indent} ///g if indent
      @mergeInterpolationTokens tokens, {delimiter}, (value, i) =>
        value = @formatString value, delimiter: quote
        value = value.replace indentRegex, '\n' if indentRegex
        value = value.replace LEADING_BLANK_LINE,  '' if i is 0
        value = value.replace TRAILING_BLANK_LINE, '' if i is $
        value
    else
      @mergeInterpolationTokens tokens, {delimiter}, (value, i) =>
        value = @formatString value, delimiter: quote
        value = value.replace SIMPLE_STRING_OMIT, (match, offset) ->
          if (i is 0 and offset is 0) or
             (i is $ and offset + match.length is value.length)
            ''
          else
            ' '
        value

    end

  # Matches JSX(-Haml) elements
  jsxToken: ->
    originalChunk = @chunk
    return 0 unless @matchJsxElement({topLevel: yes})
    originalChunk.length - @chunk.length

  consumeChunk: (length) ->
    return unless length
    [@chunkLine, @chunkColumn] = @getLineAndColumnFromChunk length
    @chunk = @chunk[length..]
    length

  matchJsxElement: (opts = {}) ->
    {topLevel} = opts
    return unless (matchedHamlElement = @matchJsxHamlElement(opts)) or (matchedTag = @matchJsxStartTag(opts))
    {elementName} = matchedHamlElement ? matchedTag

    if matchedHamlElement
      consumedWhitespace = @whitespaceToken() # consume any trailing whitespace
      @consumeChunk consumedWhitespace
      return {} if JSX_ELEMENT_IMMEDIATE_CLOSERS.exec(@chunk)
      hasIndentedBody = 'indent' is @lineToken(dry: yes)
      return @matchJsxInlineBody({elementName, consumedWhitespace}) unless hasIndentedBody
      return @matchJsxIndentedBody({elementName, topLevel})

    return {} if matchedTag?.selfClosed

    @matchJsxTagBody({elementName})

  matchJsxTagBody: ({elementName}) ->
    @token 'JSX_ELEMENT_BODY_START', elementName, 0, 0
    @consumeChunk(indentedBody = followsNewline = @lineToken()) # consume indent
    endTag = "</#{elementName}>"
    errorExpectedEndTag = =>
      @error "expected JSX end tag #{endTag}"
    originalIndent = @indent
    followsWhitespace = followsNewline
    loop
      {popLevels, trailingWhitespace: followsWhitespace} =
        @matchJsxElementIndentedChild {followsNewline, followsWhitespace, preserveWhitespace: not indentedBody}
      errorExpectedEndTag() if popLevels or not @chunk or (outdentNext = 'outdent' is @lineToken(dry: yes)) and not indentedBody
      if outdentNext
        {numOutdents, consumed} = @lineToken(returnNumOutdents: yes, noNewlines: yes)
        errorExpectedEndTag() if numOutdents > 1
        @consumeChunk consumed
        justOutdented = yes
      if /// ^ #{endTag} ///.exec(@chunk)
        @pair endTag
        @token 'JSX_END_TAG', endTag
        @consumeChunk endTag.length
        return {}
      # TODO: error on stray <
      errorExpectedEndTag() if justOutdented and @indent < originalIndent
      followsNewline = @lineToken(dry: yes)

  matchJsxStartTag: ({allowLeadingWhitespace, topLevel, followsNewline, followsWhitespace} = {}) ->
    tagRegex =
      if allowLeadingWhitespace
        JSX_TAG_LEADING_WHITESPACE
      else
        JSX_TAG
    return unless match = tagRegex.exec(@chunk)
    [[], tagOpener, elementName] = match
    followsWhitespace = yes if tagOpener.length > 1
    @token(
      if followsWhitespace
        'JSX_INLINE_ELEMENT'
      else
        'JSX_IMMEDIATE_INLINE_ELEMENT'
      ''
    ) unless topLevel or followsNewline
    token = @makeToken 'JSX_START_TAG_START', '<'
    @ends.push {tag: '>', origin: token}
    @tokens.push token
    @consumeChunk tagOpener.length
    @token 'JSX_ELEMENT_NAME', elementName
    @consumeChunk elementName.length
    ret = @matchJsxTagAttributes({elementName})
    selfClosed = ret?.selfClosed
    {elementName, selfClosed}

  matchJsxHamlElement: ({allowLeadingWhitespace, allowLeadingDotClass, topLevel, followsNewline, followsWhitespace}) ->
    elementRegex =
      if allowLeadingWhitespace
        JSX_ELEMENT_LEADING_WHITESPACE
      else
        JSX_ELEMENT
    if match = elementRegex.exec(@chunk)
      [openingTag, elementName] = match
      followsWhitespace = yes if openingTag.length > elementName.length
      @token(
        if followsWhitespace
          'JSX_INLINE_ELEMENT'
        else
          'JSX_IMMEDIATE_INLINE_ELEMENT'
        ''
      ) unless topLevel or followsNewline
      @token 'JSX_ELEMENT_NAME', elementName, 0, openingTag.length
      @consumeChunk openingTag.length
      @matchJsxHamlShorthands({allowLeadingDotClass: yes})
    else if @matchJsxHamlShorthands({allowLeadingDotClass, allowLeadingWhitespace, addImplicitElementName: yes})
      elementName = 'div'
    else return

    matchedParenthesizedAttributes = @matchJsxParenthesizedAttributes()
    @matchJsxObjectAttributes()
    @matchJsxParenthesizedAttributes() unless matchedParenthesizedAttributes # could be before/after object-style attributes
    {elementName}

  matchJsxHamlShorthands: (opts = {}) ->
    {allowLeadingDotClass, allowLeadingWhitespace, addImplicitElementName} = opts
    allowLeadingDotClass ?= @jsxLeadingDotClassAllowed()
    matchedId = @matchJsxIdShorthand({addImplicitElementName, allowLeadingWhitespace})
    unless matchedId
      return unless allowLeadingDotClass
      return unless @matchJsxClassShorthand({addImplicitElementName, allowLeadingWhitespace})
    loop
      justMatchedId = no
      matchedId = justMatchedId = @matchJsxIdShorthand() unless matchedId
      matchedClass = @matchJsxClassShorthand()
      return yes unless justMatchedId or matchedClass

  matchJsxIdShorthand: (opts = {})->
    {addImplicitElementName, allowLeadingWhitespace} = opts
    regex =
      if allowLeadingWhitespace
        JSX_ID_SHORTHAND_LEADING_WHITESPACE
      else
        JSX_ID_SHORTHAND
    return unless match = regex.exec(@chunk)
    @token 'JSX_ELEMENT_NAME', 'div', 0, 0 if addImplicitElementName
    [[], symbol, id] = match
    @token 'JSX_ID_SHORTHAND_SYMBOL', '#'
    @consumeChunk symbol.length
    @token 'JSX_ID_SHORTHAND', id
    @consumeChunk id.length
    yes

  matchJsxClassShorthand: (opts = {})->
    {addImplicitElementName, allowLeadingWhitespace} = opts
    regex =
      if allowLeadingWhitespace
        JSX_CLASS_SHORTHAND_LEADING_WHITESPACE
      else
        JSX_CLASS_SHORTHAND
    return unless match = regex.exec(@chunk)
    @token 'JSX_ELEMENT_NAME', 'div', 0, 0 if addImplicitElementName
    [[], symbol, isInterpreted, klass] = match
    @token 'JSX_CLASS_SHORTHAND_SYMBOL', '.'
    @consumeChunk symbol.length
    if isInterpreted
      [line, column] = @getLineAndColumnFromChunk 0
      {tokens: nested, index} =
        new Lexer().tokenize @chunk, {line, column, untilBalanced: on}

      [open, ..., close] = nested
      open[0]  = 'CALL_START'
      close[0] = 'CALL_END'
      close.origin = ['', 'end of interpreted JSX class', close[2]]

      # Remove leading 'TERMINATOR' (if any).
      nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

      @tokens.push nested...
      @consumeChunk index
    else
      @token 'JSX_CLASS_SHORTHAND', klass
      @consumeChunk klass.length
    yes

  matchJsxIndentedBody: ({elementName, topLevel}) ->
    @token 'JSX_ELEMENT_BODY_START', elementName, 0, 0
    @consumeChunk @lineToken() # consume indent
    followsNewline = followsWhitespace = yes
    loop
      {popLevels, trailingWhitespace: followsWhitespace} = @matchJsxElementIndentedChild {followsNewline, followsWhitespace}
      if popLevels
        @token 'TERMINATOR', '\n', 0, 0 if topLevel
        return popLevels: popLevels - 1
      if not @chunk or 'outdent' is @lineToken(dry: yes)
        {numOutdents, consumed} = @lineToken(returnNumOutdents: yes, noNewlines: not topLevel)
        @consumeChunk consumed
        return popLevels: numOutdents - 1
      followsNewline = @lineToken(dry: yes) or popLevels?
    # TODO: error on stray <

  matchJsxInlineBody: ({elementName, consumedWhitespace}) ->
    match = JSX_ELEMENT_INLINE_EQUALS_EXPRESSION.exec(@chunk)
    if match
      [full, equals, expression] = match
      @token 'JSX_ELEMENT_BODY_START', elementName, 0, 0
      @token '{', '=', 0, 0
      @consumeChunk equals.length

      [line, column] = @getLineAndColumnFromChunk 0
      nested = new Lexer().tokenize expression, {line, column}

      # Remove leading 'TERMINATOR' (if any).
      nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

      @jsxForceExpression({nested})

      @tokens.push nested...
      @consumeChunk expression.length
      [..., close] = nested
      @token '}', '}', 0, 0, ['', 'end of inline equals expression', close[2]]
      @token 'JSX_ELEMENT_INLINE_BODY_END', elementName, 0, 0
      return {}
    return {} unless JSX_ELEMENT_INLINE_BODY_START.exec(@chunk)
    @error 'must include whitespace before JSX element body' unless consumedWhitespace or not @chunk

    alreadyStarted = no
    startBody = =>
      @token 'JSX_ELEMENT_BODY_START', elementName, 0, 0
      alreadyStarted = yes

    loop
      # followsWhitespace = yes if @consumeChunk(@whitespaceToken()) and alreadyStarted
      @consumeChunk @whitespaceToken() unless alreadyStarted
      if matchedTag = @matchJsxStartTag()
        {elementName, selfClosed} = matchedTag
        @matchJsxTagBody({elementName}) unless selfClosed
      else if match = JSX_ELEMENT_INLINE_CONTENT.exec(@chunk)
        startBody() unless alreadyStarted
        [content] = match
        @token 'JSX_ELEMENT_INLINE_CONTENT', content
        @consumeChunk content.length
      else if match = JSX_ELEMENT_INLINE_EXPRESSION_START.exec(@chunk)
        startBody() unless alreadyStarted
        endOfExpressionOffset = @offsetOfNextOutdent(yes)
        [line, column] = @getLineAndColumnFromChunk 0
        {tokens: nested, index} = new Lexer().tokenize @chunk[...endOfExpressionOffset], {line, column, untilBalanced: on}

        # Remove leading 'TERMINATOR' (if any).
        nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

        @jsxForceExpression({nested, inset: 1})

        [open, ..., close] = nested
        close.origin = ['', 'end of inline expression', close[2]]
        open[0] = 'JSX_IMMEDIATE_INLINE_EXPRESSION_START'
          # if followsWhitespace
          #   'JSX_INLINE_EXPRESSION_START'
          # else
          #   'JSX_IMMEDIATE_INLINE_EXPRESSION_START'

        @tokens.push nested...
        @consumeChunk index
      else break # TODO: error on stray <
    @token 'JSX_ELEMENT_INLINE_BODY_END', elementName, 0, 0
    {}

  matchJsxObjectAttributes: ->
    return unless JSX_OBJECT_ATTRIBUTES_START.exec(@chunk)

    @token 'JSX_OBJECT_ATTRIBUTES_START', '{', 0, 0
    # TODO: should use offsetOfNextOutdent() to not look past outdent for closing }?
    [line, column] = @getLineAndColumnFromChunk 0
    {tokens: nested, index} =
      new Lexer().tokenize @chunk, {line, column, untilBalanced: on}

    # TODO: check for non-null nested here and elsewhere?
    [..., close] = nested
    close.origin = ['', 'end of object attributes', close[2]]

    # Remove leading 'TERMINATOR' (if any).
    nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

    @tokens.push nested...
    @consumeChunk index
    @token 'JSX_OBJECT_ATTRIBUTES_END', '}', 0, 0
    yes

  matchJsxTagAttributes: ({elementName}) ->
    @matchJsxNormalAttributes
      reachedEnd: =>
        if JSX_TAG_ATTRIBUTES_END.exec(@chunk)
          @pair '>'
          token = @makeToken 'JSX_START_TAG_END', '>'
          @ends.push {tag: "</#{elementName}>", origin: token}
          @tokens.push token
          @consumeChunk '>'.length
          return yes
        return no unless JSX_TAG_SELF_CLOSE.exec(@chunk)
        @pair '>'
        @token 'JSX_START_TAG_END', '>', 0, 0
        @token 'JSX_ELEMENT_BODY_START', elementName, 0, 0
        endTag = "</#{elementName}>"
        @token 'JSX_END_TAG', endTag, 0, 0
        @consumeChunk '/>'.length
        selfClosed: yes

  matchJsxParenthesizedAttributes: ->
    return unless JSX_PARENTHESIZED_ATTRIBUTES_START.exec(@chunk)

    token = @makeToken 'JSX_PARENTHESIZED_ATTRIBUTES_START', '('
    @ends.push {tag: 'JSX_PARENTHESIZED_ATTRIBUTES_END', origin: token}
    @tokens.push token
    @consumeChunk '('.length

    @matchJsxNormalAttributes
      reachedEnd: =>
        return no unless JSX_PARENTHESIZED_ATTRIBUTES_END.exec(@chunk)
        @pair 'JSX_PARENTHESIZED_ATTRIBUTES_END'
        @token 'JSX_PARENTHESIZED_ATTRIBUTES_END', ')'
        @consumeChunk ')'.length
        yes

  matchJsxNormalAttributes: ({reachedEnd}) ->
    loop
      @consumeChunk @whitespaceToken()
      @consumeChunk @lineToken()
      break if end = reachedEnd()
      @error 'expected JSX attribute' unless match = JSX_PARENTHESIZED_ATTRIBUTE.exec(@chunk)
      [full, name, preEqualsSpace, postEqualsSpace, startExpressionValue, doubleQuotedStringValue, singleQuotedStringValue] = match
      @token 'JSX_ATTRIBUTE_NAME', name
      @consumeChunk name.length + preEqualsSpace.length
      @token '=', '='
      @consumeChunk '='.length + postEqualsSpace.length
      if stringValue = doubleQuotedStringValue ? singleQuotedStringValue
        @token 'STRING', stringValue
        @consumeChunk stringValue.length
      else
        [line, column] = @getLineAndColumnFromChunk 0
        {tokens: nested, index} =
          new Lexer().tokenize @chunk, {line, column, untilBalanced: on}

        [..., close] = nested
        close.origin = ['', 'end of attribute expression value', close[2]]

        # Remove leading 'TERMINATOR' (if any).
        nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

        @jsxForceExpression({nested, inset: 1})

        @tokens.push nested...
        @consumeChunk index
    end ? yes

  matchJsxElementIndentedChild: (opts) ->
    {followsNewline, followsWhitespace, preserveWhitespace} = opts

    @matchJsxElementIndentedExpression(opts)      ? \
    @matchJsxElement({followsNewline, followsWhitespace, allowLeadingWhitespace: not preserveWhitespace, allowLeadingDotClass: yes}) ? \
    @matchJsxElementIndentedContentLine(opts)

  offsetOfNextOutdent: (greaterThan = no) ->
    unless greaterThan
      offsetOfNextNewline = do =>
        return unless match = /// ^ ([^\n]*) \n ///.exec @chunk
        [full, nonNewlines] = match
        nonNewlines.length
      if offsetOfNextNewline
        [line, column] = @getLineAndColumnFromChunk 0
        try
          new Lexer().tokenize @chunk[...offsetOfNextNewline], {line, column}
        catch error
          throw error unless match = /^missing (\S+)/.exec error.message
          [full, unclosed] = match
    match =
      (if greaterThan
        ///
          \n
          #{' '} {0, #{@indent - 1}}
          \S
        ///
      else if unclosed
        ///
          \n
          (?:
            #{' '} {0, #{@indent - 1}}
            \S
              |
            #{' '} {0, #{@indent}}
            [^#{ '\\' + unclosed }\s]
          )
        ///
      else
        ///
          \n
          #{' '} {0, #{@indent}}
          \S
        ///
      ).exec @chunk
    return @chunk.length unless match # no outdent remaining

    match.index

  matchJsxElementIndentedExpression: ({followsNewline, followsWhitespace, preserveWhitespace}) ->
    if followsNewline and match = JSX_ELEMENT_INDENTED_EQUALS_EXPRESSION_START.exec(@chunk)
      @token '{', '=', 0, 0
      @consumeChunk match[0].length

      endOfExpressionOffset = @offsetOfNextOutdent()
      [line, column] = @getLineAndColumnFromChunk 0
      nested = new Lexer().tokenize @chunk[...endOfExpressionOffset], {line, column}

      # Remove leading 'TERMINATOR' (if any).
      nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

      @jsxForceExpression({nested})

      @tokens.push nested...
      @consumeChunk endOfExpressionOffset

      [..., close] = nested
      @token '}', '}', 0, 0, ['', 'end of equals expression', close[2]]
      return {}

    if match = (if preserveWhitespace then JSX_ELEMENT_INLINE_EXPRESSION_START else JSX_ELEMENT_INDENTED_EXPRESSION_START).exec(@chunk)
      endOfExpressionOffset = @offsetOfNextOutdent(yes)

      # consume but don't record line token(s)
      if match = WHITESPACE_INCLUDING_NEWLINES.exec(@chunk)
        leadingWhitespace = yes
        @consumeChunk match[0].length
      else if followsWhitespace
        leadingWhitespace = yes

      [line, column] = @getLineAndColumnFromChunk 0
      {tokens: nested, index} = new Lexer().tokenize @chunk[...endOfExpressionOffset], {line, column, untilBalanced: on, initialIndent: @indent}

      # Remove leading 'TERMINATOR' (if any).
      nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

      @jsxForceExpression({nested, inset: 1})

      [open, ..., close] = nested
      close.origin = ['', 'end of indented expression', close[2]]
      unless followsNewline
        open[0] =
          if leadingWhitespace
            'JSX_INLINE_EXPRESSION_START'
          else
            'JSX_IMMEDIATE_INLINE_EXPRESSION_START'

      @tokens.push nested...
      @consumeChunk index

      return {}

  jsxForceExpression: ({nested, inset = 0}) ->
    return unless (token for token in nested when token[0] in ['FOR', 'SWITCH', 'WHILE', 'UNTIL', 'IF']).length

    nested.splice inset, 0,
      @makeToken 'IDENTIFIER', 'FORCE_EXPRESSION', 0, 0
      @makeToken '=', '=', 0, 0
      @makeToken '(', '(', 0, 0
    nested.splice nested.length - inset, 0,
      @makeToken ')', ')', 0, 0

  matchJsxElementIndentedContentLine: ({preserveWhitespace, followsNewline}) ->
    [match, content] = JSX_ELEMENT_INDENTED_CONTENT_LINE.exec(@chunk)
    return {} unless match.length
    trailingWhitespace = TRAILING_SPACES.exec match
    if preserveWhitespace or not followsNewline
      content = match
    else
      content = content.trim()
    @token(
      if followsNewline
        'JSX_ELEMENT_CONTENT'
      else
        'JSX_ELEMENT_INLINE_CONTENT'
      content, 0, match.length
    ) if NON_WHITESPACE.exec(match) or match.length and preserveWhitespace

    @consumeChunk match.length
    {trailingWhitespace}

  # Matches and consumes comments.
  commentToken: ->
    return 0 unless match = @chunk.match COMMENT
    [comment, here] = match
    if here
      if match = HERECOMMENT_ILLEGAL.exec comment
        @error "block comments cannot contain #{match[0]}",
          offset: match.index, length: match[0].length
      if here.indexOf('\n') >= 0
        here = here.replace /// \n #{repeat ' ', @indent} ///g, '\n'
      @token 'HERECOMMENT', here, 0, comment.length
    comment.length

  # Matches JavaScript interpolated directly into the source via backticks.
  jsToken: ->
    return 0 unless @chunk.charAt(0) is '`' and
      (match = HERE_JSTOKEN.exec(@chunk) or JSTOKEN.exec(@chunk))
    # Convert escaped backticks to backticks, and escaped backslashes
    # just before escaped backticks to backslashes
    script = match[1].replace /\\+(`|$)/g, (string) ->
      # `string` is always a value like '\`', '\\\`', '\\\\\`', etc.
      # By reducing it to its latter half, we turn '\`' to '`', '\\\`' to '\`', etc.
      string[-Math.ceil(string.length / 2)..]
    @token 'JS', script, 0, match[0].length
    match[0].length

  # Matches regular expression literals, as well as multiline extended ones.
  # Lexing regular expressions is difficult to distinguish from division, so we
  # borrow some basic heuristics from JavaScript and Ruby.
  regexToken: ->
    switch
      when match = REGEX_ILLEGAL.exec @chunk
        @error "regular expressions cannot begin with #{match[2]}",
          offset: match.index + match[1].length
      when match = @matchWithInterpolations HEREGEX, '///'
        {tokens, index} = match
      when match = REGEX.exec @chunk
        [regex, body, closed] = match
        @validateEscapes body, isRegex: yes, offsetInChunk: 1
        index = regex.length
        prev = @prev()
        if prev
          if prev.spaced and prev[0] in CALLABLE
            return 0 if not closed or POSSIBLY_DIVISION.test regex
          else if prev[0] in NOT_REGEX
            return 0
        @error 'missing / (unclosed regex)' unless closed
      else
        return 0

    [flags] = REGEX_FLAGS.exec @chunk[index..]
    end = index + flags.length
    origin = @makeToken 'REGEX', null, 0, end
    switch
      when not VALID_FLAGS.test flags
        @error "invalid regular expression flags #{flags}", offset: index, length: flags.length
      when regex or tokens.length is 1
        if body
          body = @formatRegex body, { flags, delimiter: '/' }
        else
          body = @formatHeregex tokens[0][1], { flags }
        @token 'REGEX', "#{@makeDelimitedLiteral body, delimiter: '/'}#{flags}", 0, end, origin
      else
        @token 'REGEX_START', '(', 0, 0, origin
        @token 'IDENTIFIER', 'RegExp', 0, 0
        @token 'CALL_START', '(', 0, 0
        @mergeInterpolationTokens tokens, {delimiter: '"', double: yes}, (str) =>
          @formatHeregex str, { flags }
        if flags
          @token ',', ',', index - 1, 0
          @token 'STRING', '"' + flags + '"', index - 1, flags.length
        @token ')', ')', end - 1, 0
        @token 'REGEX_END', ')', end - 1, 0

    end

  # Matches newlines, indents, and outdents, and determines which is which.
  # If we can detect that the current line is continued onto the next line,
  # then the newline is suppressed:
  #
  #     elements
  #       .each( ... )
  #       .map( ... )
  #
  # Keeps track of the level of indentation, because a single outdent token
  # can close multiple indents, so we need to know how far in we happen to be.
  lineToken: (opts = {}) ->
    {dry, returnNumOutdents, noNewlines} = opts
    return 0 unless match = MULTI_DENT.exec @chunk
    indent = match[0]

    @seenFor = no
    @seenImport = no unless @importSpecifierList
    @seenExport = no unless @exportSpecifierList

    size = indent.length - 1 - indent.lastIndexOf '\n'
    includesBlankLine = indent.split('\n').length > 2

    action =
      switch
        when size - @indebt is @indent
          'consumedIndebt'
        when size > @indent
          'indent'
        when size < @baseIndent
          'missing'
        else
           'outdent'
    return action if dry

    noNewlines ?= @unfinished({includesBlankLine})

    newIndentLiteral = if size > 0 then indent[-size..] else ''
    unless /^(.?)\1*$/.exec newIndentLiteral
      @error 'mixed indentation', offset: indent.length
      return indent.length

    minLiteralLength = Math.min newIndentLiteral.length, @indentLiteral.length
    if newIndentLiteral[...minLiteralLength] isnt @indentLiteral[...minLiteralLength]
      @error 'indentation mismatch', offset: indent.length
      return indent.length

    switch action
      when 'consumedIndebt'
        if noNewlines then @suppressNewlines() else @newlineToken 0, {includesBlankLine}
      when 'indent'
        if noNewlines or @tag() is 'RETURN'
          @indebt = size - @indent
          @suppressNewlines()
          break
        unless @tokens.length
          @baseIndent = @indent = size
          @indentLiteral = newIndentLiteral
          break
        diff = size - @indent + @outdebt
        token = @makeToken 'INDENT', diff, indent.length - size, size
        token.includesBlankLine = yes if includesBlankLine
        @tokens.push token
        @indents.push diff
        @ends.push {tag: 'OUTDENT'}
        @outdebt = @indebt = 0
        @indent = size
        @indentLiteral = newIndentLiteral
      when 'missing'
        @error 'missing indentation', offset: indent.length
      else # outdent
        @indebt = 0
        numOutdents = @outdentToken @indent - size, noNewlines, indent.length
        return {numOutdents, consumed: indent.length} if returnNumOutdents

    indent.length

  # Record an outdent token or multiple tokens, if we happen to be moving back
  # inwards past several recorded indents. Sets new @indent value.
  outdentToken: (moveOut, noNewlines, outdentLength) ->
    decreasedIndent = @indent - moveOut
    numOutdents = 0
    while moveOut > 0
      lastIndent = @indents[@indents.length - 1]
      if not lastIndent
        moveOut = 0
      else if @outdebt and moveOut <= @outdebt
        @outdebt -= moveOut
        moveOut   = 0
      else
        dent = @indents.pop() + @outdebt
        if outdentLength and @chunk[outdentLength] in INDENTABLE_CLOSERS
          decreasedIndent -= dent - moveOut
          moveOut = dent
        @outdebt = 0
        # pair might call outdentToken, so preserve decreasedIndent
        @pair 'OUTDENT'
        @token 'OUTDENT', moveOut, 0, outdentLength
        numOutdents++
        moveOut -= dent
    @outdebt -= moveOut if dent
    @tokens.pop() while @value() is ';'

    @token 'TERMINATOR', '\n', outdentLength, 0 unless @tag() is 'TERMINATOR' or noNewlines
    @indent = decreasedIndent
    @indentLiteral = @indentLiteral[...decreasedIndent]
    numOutdents

  # Matches and consumes non-meaningful whitespace. Tag the previous token
  # as being “spaced”, because there are some cases where it makes a difference.
  whitespaceToken: ->
    return 0 unless (match = WHITESPACE.exec @chunk) or
                    (nline = @chunk.charAt(0) is '\n')
    prev = @prev()
    prev[if match then 'spaced' else 'newLine'] = true if prev
    if match then match[0].length else 0

  # Generate a newline token. Consecutive newlines get merged together.
  newlineToken: (offset, opts = {}) ->
    @tokens.pop() while @value() is ';'
    unless @tag() is 'TERMINATOR'
      token = @makeToken 'TERMINATOR', '\n', offset, 0
      token.includesBlankLine = yes if opts.includesBlankLine
      @tokens.push token
    this

  # Use a `\` at a line-ending to suppress the newline.
  # The slash is removed here once its job is done.
  suppressNewlines: ->
    @tokens.pop() if @value() is '\\'
    this

  # We treat all other single characters as a token. E.g.: `( ) , . !`
  # Multi-character operators are also literal tokens, so that Jison can assign
  # the proper order of operations. There are some symbols that we tag specially
  # here. `;` and newlines are both treated as a `TERMINATOR`, we distinguish
  # parentheses that indicate a method call from regular parentheses, and so on.
  literalToken: ->
    if match = OPERATOR.exec @chunk
      [value] = match
      @tagParameters() if CODE.test value
    else
      value = @chunk.charAt 0
    tag  = value
    prev = @prev()

    if prev and value in ['=', COMPOUND_ASSIGN...]
      skipToken = false
      if value is '=' and prev[1] in ['||', '&&'] and not prev.spaced
        prev[0] = 'COMPOUND_ASSIGN'
        prev[1] += '='
        prev = @tokens[@tokens.length - 2]
        skipToken = true
      if prev and prev[0] isnt 'PROPERTY'
        origin = prev.origin ? prev
        message = isUnassignable prev[1], origin[1]
        @error message, origin[2] if message
      return value.length if skipToken

    if value is '{' and @seenImport
      @importSpecifierList = yes
    else if @importSpecifierList and value is '}'
      @importSpecifierList = no
    else if value is '{' and prev?[0] is 'EXPORT'
      @exportSpecifierList = yes
    else if @exportSpecifierList and value is '}'
      @exportSpecifierList = no

    if value is ';'
      @seenFor = @seenImport = @seenExport = no
      tag = 'TERMINATOR'
    else if value is '*' and prev[0] is 'EXPORT'
      tag = 'EXPORT_ALL'
    else if value in MATH            then tag = 'MATH'
    else if value in COMPARE         then tag = 'COMPARE'
    else if value in COMPOUND_ASSIGN then tag = 'COMPOUND_ASSIGN'
    else if value in UNARY           then tag = 'UNARY'
    else if value in UNARY_MATH      then tag = 'UNARY_MATH'
    else if value in SHIFT           then tag = 'SHIFT'
    else if value is '?' and prev?.spaced then tag = 'BIN?'
    else if prev and not prev.spaced
      if value is '(' and prev[0] in CALLABLE
        prev[0] = 'FUNC_EXIST' if prev[0] is '?'
        tag = 'CALL_START'
      else if value is '[' and prev[0] in INDEXABLE
        tag = 'INDEX_START'
        switch prev[0]
          when '?'  then prev[0] = 'INDEX_SOAK'
    token = @makeToken tag, value
    switch value
      when '(', '{', '[' then @ends.push {tag: INVERSES[value], origin: token}
      when ')', '}', ']' then @pair value
    @tokens.push @makeToken tag, value
    value.length

  # Token Manipulators
  # ------------------

  # A source of ambiguity in our grammar used to be parameter lists in function
  # definitions versus argument lists in function calls. Walk backwards, tagging
  # parameters specially in order to make things easier for the parser.
  tagParameters: ->
    return this if @tag() isnt ')'
    stack = []
    {tokens} = this
    i = tokens.length
    paramEndToken = tokens[--i]
    paramEndToken[0] = 'PARAM_END'
    while tok = tokens[--i]
      switch tok[0]
        when ')'
          stack.push tok
        when '(', 'CALL_START'
          if stack.length then stack.pop()
          else if tok[0] is '('
            tok[0] = 'PARAM_START'
            return this
          else
            paramEndToken[0] = 'CALL_END'
            return this
    this

  # Close up all remaining open blocks at the end of the file.
  closeIndentation: ->
    @outdentToken @indent

  # Match the contents of a delimited token and expand variables and expressions
  # inside it using Ruby-like notation for substitution of arbitrary
  # expressions.
  #
  #     "Hello #{name.capitalize()}."
  #
  # If it encounters an interpolation, this method will recursively create a new
  # Lexer and tokenize until the `{` of `#{` is balanced with a `}`.
  #
  #  - `regex` matches the contents of a token (but not `delimiter`, and not
  #    `#{` if interpolations are desired).
  #  - `delimiter` is the delimiter of the token. Examples are `'`, `"`, `'''`,
  #    `"""` and `///`.
  #
  # This method allows us to have strings within interpolations within strings,
  # ad infinitum.
  matchWithInterpolations: (regex, delimiter, closingDelimiter, interpolators) ->
    closingDelimiter ?= delimiter
    interpolators ?= /^#\{/

    tokens = []
    offsetInChunk = delimiter.length
    return null unless @chunk[...offsetInChunk] is delimiter
    str = @chunk[offsetInChunk..]
    loop
      [strPart] = regex.exec str

      @validateEscapes strPart, {isRegex: delimiter.charAt(0) is '/', offsetInChunk}

      # Push a fake `'NEOSTRING'` token, which will get turned into a real string later.
      tokens.push @makeToken 'NEOSTRING', strPart, offsetInChunk

      str = str[strPart.length..]
      offsetInChunk += strPart.length

      break unless match = interpolators.exec str
      [interpolator] = match

      # To remove the `#` in `#{`.
      interpolationOffset = interpolator.length - 1
      [line, column] = @getLineAndColumnFromChunk offsetInChunk + interpolationOffset
      rest = str[interpolationOffset..]
      {tokens: nested, index} =
        new Lexer().tokenize rest, line: line, column: column, untilBalanced: on
      # Account for the `#` in `#{`
      index += interpolationOffset

      braceInterpolator = str[index - 1] is '}'
      if braceInterpolator
        # Turn the leading and trailing `{` and `}` into parentheses. Unnecessary
        # parentheses will be removed later.
        [open, ..., close] = nested
        open[0]  = open[1]  = '('
        close[0] = close[1] = ')'
        close.origin = ['', 'end of interpolation', close[2]]

      # Remove leading `'TERMINATOR'` (if any).
      nested.splice 1, 1 if nested[1]?[0] is 'TERMINATOR'

      unless braceInterpolator
        # We are not using `{` and `}`, so wrap the interpolated tokens instead.
        open = @makeToken '(', '(', offsetInChunk, 0
        close = @makeToken ')', ')', offsetInChunk + index, 0
        nested = [open, nested..., close]

      # Push a fake `'TOKENS'` token, which will get turned into real tokens later.
      tokens.push ['TOKENS', nested]

      str = str[index..]
      offsetInChunk += index

    unless str[...closingDelimiter.length] is closingDelimiter
      @error "missing #{closingDelimiter}", length: delimiter.length

    [firstToken, ..., lastToken] = tokens
    firstToken[2].first_column -= delimiter.length
    if lastToken[1].substr(-1) is '\n'
      lastToken[2].last_line += 1
      lastToken[2].last_column = closingDelimiter.length - 1
    else
      lastToken[2].last_column += closingDelimiter.length
    lastToken[2].last_column -= 1 if lastToken[1].length is 0

    {tokens, index: offsetInChunk + closingDelimiter.length}

  # Merge the array `tokens` of the fake token types `'TOKENS'` and `'NEOSTRING'`
  # (as returned by `matchWithInterpolations`) into the token stream. The value
  # of `'NEOSTRING'`s are converted using `fn` and turned into strings using
  # `options` first.
  mergeInterpolationTokens: (tokens, options, fn) ->
    if tokens.length > 1
      lparen = @token 'STRING_START', '(', 0, 0

    firstIndex = @tokens.length
    for token, i in tokens
      [tag, value] = token
      switch tag
        when 'TOKENS'
          # Optimize out empty interpolations (an empty pair of parentheses).
          continue if value.length is 2
          # Push all the tokens in the fake `'TOKENS'` token. These already have
          # sane location data.
          locationToken = value[0]
          tokensToPush = value
        when 'NEOSTRING'
          # Convert `'NEOSTRING'` into `'STRING'`.
          converted = fn.call this, token[1], i
          # Optimize out empty strings. We ensure that the tokens stream always
          # starts with a string token, though, to make sure that the result
          # really is a string.
          if converted.length is 0
            if i is 0
              firstEmptyStringIndex = @tokens.length
            else
              continue
          # However, there is one case where we can optimize away a starting
          # empty string.
          if i is 2 and firstEmptyStringIndex?
            @tokens.splice firstEmptyStringIndex, 2 # Remove empty string and the plus.
          token[0] = 'STRING'
          token[1] = @makeDelimitedLiteral converted, options
          locationToken = token
          tokensToPush = [token]
      if @tokens.length > firstIndex
        # Create a 0-length "+" token.
        plusToken = @token '+', '+'
        plusToken[2] =
          first_line:   locationToken[2].first_line
          first_column: locationToken[2].first_column
          last_line:    locationToken[2].first_line
          last_column:  locationToken[2].first_column
      @tokens.push tokensToPush...

    if lparen
      [..., lastToken] = tokens
      lparen.origin = ['STRING', null,
        first_line:   lparen[2].first_line
        first_column: lparen[2].first_column
        last_line:    lastToken[2].last_line
        last_column:  lastToken[2].last_column
      ]
      rparen = @token 'STRING_END', ')'
      rparen[2] =
        first_line:   lastToken[2].last_line
        first_column: lastToken[2].last_column
        last_line:    lastToken[2].last_line
        last_column:  lastToken[2].last_column

  # Pairs up a closing token, ensuring that all listed pairs of tokens are
  # correctly balanced throughout the course of the token stream.
  pair: (tag) ->
    [..., prev] = @ends
    unless tag is wanted = prev?.tag
      @error "unmatched #{tag}" unless 'OUTDENT' is wanted
      # Auto-close `INDENT` to support syntax like this:
      #
      #     el.click((event) ->
      #       el.hide())
      #
      [..., lastIndent] = @indents
      @outdentToken lastIndent, true
      return @pair tag
    @ends.pop()

  # Helpers
  # -------

  # Returns the line and column number from an offset into the current chunk.
  #
  # `offset` is a number of characters into `@chunk`.
  getLineAndColumnFromChunk: (offset) ->
    if offset is 0
      return [@chunkLine, @chunkColumn]

    if offset >= @chunk.length
      string = @chunk
    else
      string = @chunk[..offset-1]

    lineCount = count string, '\n'

    column = @chunkColumn
    if lineCount > 0
      [..., lastLine] = string.split '\n'
      column = lastLine.length
    else
      column += string.length

    [@chunkLine + lineCount, column]

  # Same as `token`, except this just returns the token without adding it
  # to the results.
  makeToken: (tag, value, offsetInChunk = 0, length = value.length) ->
    locationData = {}
    [locationData.first_line, locationData.first_column] =
      @getLineAndColumnFromChunk offsetInChunk

    # Use length - 1 for the final offset - we're supplying the last_line and the last_column,
    # so if last_column == first_column, then we're looking at a character of length 1.
    lastCharacter = if length > 0 then (length - 1) else 0
    [locationData.last_line, locationData.last_column] =
      @getLineAndColumnFromChunk offsetInChunk + lastCharacter

    token = [tag, value, locationData]

    token

  # Add a token to the results.
  # `offset` is the offset into the current `@chunk` where the token starts.
  # `length` is the length of the token in the `@chunk`, after the offset.  If
  # not specified, the length of `value` will be used.
  #
  # Returns the new token.
  token: (tag, value, offsetInChunk, length, origin) ->
    token = @makeToken tag, value, offsetInChunk, length
    token.origin = origin if origin
    @tokens.push token
    token

  # Peek at the last tag in the token stream.
  tag: ->
    [..., token] = @tokens
    token?[0]

  # Peek at the last value in the token stream.
  value: ->
    [..., token] = @tokens
    token?[1]

  # Get the previous token in the token stream.
  prev: ->
    @tokens[@tokens.length - 1]

  # Are we in the midst of an unfinished expression?
  unfinished: (opts = {}) ->
    regex =
      if @jsxLeadingDotClassAllowed(opts)
        LINE_CONTINUER_NO_DOT
      else
        LINE_CONTINUER
    regex.test(@chunk) or
    @tag() in ['\\', '.', '?.', '?::', 'UNARY', 'MATH', 'UNARY_MATH', '+', '-',
               '**', 'SHIFT', 'RELATION', 'COMPARE', '&', '^', '|', '&&', '||',
               'BIN?', 'THROW', 'EXTENDS', 'DEFAULT']

  jsxLeadingDotClassAllowed: ({includesBlankLine} = {}) ->
    return yes unless @tokens.length
    return yes if includesBlankLine
    return yes if @lastNonIndentTag() in CANT_PRECEDE_DOT_PROPERTY
    return yes if @lineToken(dry: yes) is 'indent' and @prevLineStartsWith ['IF', 'ELSE', 'FOR', 'UNLESS']
    [..., prevToken] = @tokens
    return yes if prevToken?[0]        is 'INDENT' and @prevLineStartsWith ['IF', 'ELSE', 'FOR', 'UNLESS'], offset: 1
    return yes if prevToken?.includesBlankLine
    no

  prevLineStartsWith: (tags, opts = {}) ->
    {offset = 0} = opts
    index = @tokens.length - offset
    while tag = @tokens[--index]?[0]
      break if tag in ['TERMINATOR', 'INDENT', 'OUTDENT']
    lineStarter = @tokens[index + 1]
    lineStarter?[0] in tags

  lastNonIndentTag: ->
    index = @tokens.length
    while tag = @tokens[--index]?[0]
      return tag unless tag is 'INDENT'

  formatString: (str, options) ->
    @replaceUnicodeCodePointEscapes str.replace(STRING_OMIT, '$1'), options

  formatHeregex: (str, options) ->
    @formatRegex str.replace(HEREGEX_OMIT, '$1$2'), merge(options, delimiter: '///')

  formatRegex: (str, options) ->
    @replaceUnicodeCodePointEscapes str, options

  unicodeCodePointToUnicodeEscapes: (codePoint) ->
    toUnicodeEscape = (val) ->
      str = val.toString 16
      "\\u#{repeat '0', 4 - str.length}#{str}"
    return toUnicodeEscape(codePoint) if codePoint < 0x10000
    # surrogate pair
    high = Math.floor((codePoint - 0x10000) / 0x400) + 0xD800
    low = (codePoint - 0x10000) % 0x400 + 0xDC00
    "#{toUnicodeEscape(high)}#{toUnicodeEscape(low)}"

  # Replace `\u{...}` with `\uxxxx[\uxxxx]` in regexes without `u` flag
  replaceUnicodeCodePointEscapes: (str, options) ->
    shouldReplace = options.flags? and 'u' not in options.flags
    str.replace UNICODE_CODE_POINT_ESCAPE, (match, escapedBackslash, codePointHex, offset) =>
      return escapedBackslash if escapedBackslash

      codePointDecimal = parseInt codePointHex, 16
      if codePointDecimal > 0x10ffff
        @error "unicode code point escapes greater than \\u{10ffff} are not allowed",
          offset: offset + options.delimiter.length
          length: codePointHex.length + 4
      return match unless shouldReplace

      @unicodeCodePointToUnicodeEscapes codePointDecimal

  # Validates escapes in strings and regexes.
  validateEscapes: (str, options = {}) ->
    invalidEscapeRegex =
      if options.isRegex
        REGEX_INVALID_ESCAPE
      else
        STRING_INVALID_ESCAPE
    match = invalidEscapeRegex.exec str
    return unless match
    [[], before, octal, hex, unicodeCodePoint, unicode] = match
    message =
      if octal
        "octal escape sequences are not allowed"
      else
        "invalid escape sequence"
    invalidEscape = "\\#{octal or hex or unicodeCodePoint or unicode}"
    @error "#{message} #{invalidEscape}",
      offset: (options.offsetInChunk ? 0) + match.index + before.length
      length: invalidEscape.length

  # Constructs a string or regex by escaping certain characters.
  makeDelimitedLiteral: (body, options = {}) ->
    body = '(?:)' if body is '' and options.delimiter is '/'
    regex = ///
        (\\\\)                               # Escaped backslash.
      | (\\0(?=[1-7]))                       # Null character mistaken as octal escape.
      | \\?(#{options.delimiter})            # (Possibly escaped) delimiter.
      | \\?(?: (\n)|(\r)|(\u2028)|(\u2029) ) # (Possibly escaped) newlines.
      | (\\.)                                # Other escapes.
    ///g
    body = body.replace regex, (match, backslash, nul, delimiter, lf, cr, ls, ps, other) -> switch
      # Ignore escaped backslashes.
      when backslash then (if options.double then backslash + backslash else backslash)
      when nul       then '\\x00'
      when delimiter then "\\#{delimiter}"
      when lf        then '\\n'
      when cr        then '\\r'
      when ls        then '\\u2028'
      when ps        then '\\u2029'
      when other     then (if options.double then "\\#{other}" else other)
    "#{options.delimiter}#{body}#{options.delimiter}"

  # Throws an error at either a given offset from the current chunk or at the
  # location of a token (`token[2]`).
  error: (message, options = {}) ->
    location =
      if 'first_line' of options
        options
      else
        [first_line, first_column] = @getLineAndColumnFromChunk options.offset ? 0
        {first_line, first_column, last_column: first_column + (options.length ? 1) - 1}
    throwSyntaxError message, location

# Helper functions
# ----------------

isUnassignable = (name, displayName = name) -> switch
  when name in [JS_KEYWORDS..., COFFEE_KEYWORDS...]
    "keyword '#{displayName}' can't be assigned"
  when name in STRICT_PROSCRIBED
    "'#{displayName}' can't be assigned"
  when name in RESERVED
    "reserved word '#{displayName}' can't be assigned"
  else
    false

exports.isUnassignable = isUnassignable

# `from` isn’t a CoffeeScript keyword, but it behaves like one in `import` and
# `export` statements (handled above) and in the declaration line of a `for`
# loop. Try to detect when `from` is a variable identifier and when it is this
# “sometimes” keyword.
isForFrom = (prev) ->
  if prev[0] is 'IDENTIFIER'
    # `for i from from`, `for from from iterable`
    if prev[1] is 'from'
      prev[1][0] = 'IDENTIFIER'
      yes
    # `for i from iterable`
    yes
  # `for from…`
  else if prev[0] is 'FOR'
    no
  # `for {from}…`, `for [from]…`, `for {a, from}…`, `for {a: from}…`
  else if prev[1] in ['{', '[', ',', ':']
    no
  else
    yes

# Constants
# ---------

# Keywords that CoffeeScript shares in common with JavaScript.
JS_KEYWORDS = [
  'true', 'false', 'null', 'this'
  'new', 'delete', 'typeof', 'in', 'instanceof'
  'return', 'throw', 'break', 'continue', 'debugger', 'yield', 'await'
  'if', 'else', 'switch', 'for', 'while', 'do', 'try', 'catch', 'finally'
  'class', 'extends', 'super'
  'import', 'export', 'default'
]

# CoffeeScript-only keywords.
COFFEE_KEYWORDS = [
  'undefined', 'Infinity', 'NaN'
  'then', 'unless', 'until', 'loop', 'of', 'by', 'when'
]

COFFEE_ALIAS_MAP =
  and  : '&&'
  or   : '||'
  is   : '=='
  isnt : '!='
  not  : '!'
  yes  : 'true'
  no   : 'false'
  on   : 'true'
  off  : 'false'

COFFEE_ALIASES  = (key for key of COFFEE_ALIAS_MAP)
COFFEE_KEYWORDS = COFFEE_KEYWORDS.concat COFFEE_ALIASES

# The list of keywords that are reserved by JavaScript, but not used, or are
# used by CoffeeScript internally. We throw an error when these are encountered,
# to avoid having a JavaScript error at runtime.
RESERVED = [
  'case', 'function', 'var', 'void', 'with', 'const', 'let', 'enum'
  'native', 'implements', 'interface', 'package', 'private'
  'protected', 'public', 'static'
]

STRICT_PROSCRIBED = ['arguments', 'eval']

# The superset of both JavaScript keywords and reserved words, none of which may
# be used as identifiers or properties.
exports.JS_FORBIDDEN = JS_KEYWORDS.concat(RESERVED).concat(STRICT_PROSCRIBED)

# The character code of the nasty Microsoft madness otherwise known as the BOM.
BOM = 65279

# Token matching regexes.
IDENTIFIER = /// ^
  (?!\d)
  ( (?: (?!\s)[$\w\x7f-\uffff] )+ )
  ( [^\n\S]* : (?!:) )?  # Is this a property name?
///

NUMBER     = ///
  ^ 0b[01]+    |              # binary
  ^ 0o[0-7]+   |              # octal
  ^ 0x[\da-f]+ |              # hex
  ^ \d*\.?\d+ (?:e[+-]?\d+)?  # decimal
///i

OPERATOR   = /// ^ (
  ?: [-=]>             # function
   | [-+*/%<>&|^!?=]=  # compound assign / compare
   | >>>=?             # zero-fill right shift
   | ([-+:])\1         # doubles
   | ([&|<>*/%])\2=?   # logic / shift / power / floor division / modulo
   | \?(\.|::)         # soak access
   | \.{2,3}           # range or splat
) ///

WHITESPACE = /^[^\n\S]+/

COMMENT    = /^###([^#][\s\S]*?)(?:###[^\n\S]*|###$)|^(?:\s*#(?!##[^#])(?![a-zA-Z]).*)+/

CODE       = /^[-=]>/

MULTI_DENT = /^(?:\n[^\n\S]*)+/

JSTOKEN      = ///^ `(?!``) ((?: [^`\\] | \\[\s\S]           )*) `   ///
HERE_JSTOKEN = ///^ ```     ((?: [^`\\] | \\[\s\S] | `(?!``) )*) ``` ///

JSX_ELEMENT =                    /// ^     %([a-zA-Z][a-zA-Z_0-9]*) ///
JSX_ELEMENT_LEADING_WHITESPACE = /// ^ \s* %([a-zA-Z][a-zA-Z_0-9]*) ///
JSX_ID_SHORTHAND =                    /// ^     (\#) ([a-zA-Z][a-zA-Z_0-9\-]*) ///
JSX_ID_SHORTHAND_LEADING_WHITESPACE = /// ^ (\s* \#) ([a-zA-Z][a-zA-Z_0-9\-]*) ///
JSX_CLASS_SHORTHAND =                    /// ^     (\.) (?: (\() | ([a-zA-Z][a-zA-Z_0-9\-]*)) ///
JSX_CLASS_SHORTHAND_LEADING_WHITESPACE = /// ^ (\s* \.) (?: (\() | ([a-zA-Z][a-zA-Z_0-9\-]*)) ///
JSX_ELEMENT_IMMEDIATE_CLOSERS = /// ^ (?: \, | \} | \) | \] | for\s | unless\s | if\s ) ///
JSX_ELEMENT_INLINE_EQUALS_EXPRESSION = /// ^ (= \s*) ([^\n]+) ///
JSX_ELEMENT_INLINE_BODY_START = /// ^ [^\n] ///
JSX_ELEMENT_INLINE_CONTENT = /// ^ [^\n\{<]+ ///
JSX_ELEMENT_INLINE_EXPRESSION_START = /// ^ \{ ///
JSX_ELEMENT_INDENTED_EQUALS_EXPRESSION_START = /// ^ \s* = ///
JSX_ELEMENT_INDENTED_EXPRESSION_START = /// ^ \s* { ///
JSX_ELEMENT_INDENTED_CONTENT_LINE = /// ^ \s* ([^\n\{<]*) ///
JSX_PARENTHESIZED_ATTRIBUTES_START = /// ^ \( ///
JSX_PARENTHESIZED_ATTRIBUTES_END   = /// ^ \) ///
JSX_PARENTHESIZED_ATTRIBUTE = ///
  ^
  ([a-zA-Z][a-zA-Z_\-0-9]*)      # attribute name
  (\s*)
  =
  (\s*) 
  (?:
    (\{)                           # start expression attribute value
    |
    (" (?: [^\\"] | \\[\s\S] )* ") # double-quoted string attribute value
    |
    (' (?: [^\\'] | \\[\s\S] )* ') # single-quoted string attribute value
  )
///
JSX_OBJECT_ATTRIBUTES_START = /// ^ \{ ///
JSX_TAG =                    /// ^     (<) ([a-zA-Z][a-zA-Z_0-9]*) ///
JSX_TAG_LEADING_WHITESPACE = /// ^ (\s* <) ([a-zA-Z][a-zA-Z_0-9]*) ///
JSX_TAG_ATTRIBUTES_END = /// ^ > ///
JSX_TAG_SELF_CLOSE = /// ^ /> ///
NON_WHITESPACE = /// \S ///
WHITESPACE_INCLUDING_NEWLINES = /^\s+/

# String-matching-regexes.
STRING_START   = /^(?:'''|"""|'|")/

STRING_SINGLE  = /// ^(?: [^\\']  | \\[\s\S]                      )* ///
STRING_DOUBLE  = /// ^(?: [^\\"#] | \\[\s\S] |           \#(?!\{) )* ///
HEREDOC_SINGLE = /// ^(?: [^\\']  | \\[\s\S] | '(?!'')            )* ///
HEREDOC_DOUBLE = /// ^(?: [^\\"#] | \\[\s\S] | "(?!"") | \#(?!\{) )* ///

STRING_OMIT    = ///
    ((?:\\\\)+)      # Consume (and preserve) an even number of backslashes.
  | \\[^\S\n]*\n\s*  # Remove escaped newlines.
///g
SIMPLE_STRING_OMIT = /\s*\n\s*/g
HEREDOC_INDENT     = /\n+([^\n\S]*)(?=\S)/g

# Regex-matching-regexes.
REGEX = /// ^
  / (?!/) ((
  ?: [^ [ / \n \\ ]  # Every other thing.
   | \\[^\n]         # Anything but newlines escaped.
   | \[              # Character class.
       (?: \\[^\n] | [^ \] \n \\ ] )*
     \]
  )*) (/)?
///

REGEX_FLAGS  = /^\w*/
VALID_FLAGS  = /^(?!.*(.).*\1)[imguy]*$/

HEREGEX      = /// ^(?: [^\\/#] | \\[\s\S] | /(?!//) | \#(?!\{) )* ///

HEREGEX_OMIT = ///
    ((?:\\\\)+)     # Consume (and preserve) an even number of backslashes.
  | \\(\s)          # Preserve escaped whitespace.
  | \s+(?:#.*)?     # Remove whitespace and comments.
///g

REGEX_ILLEGAL = /// ^ ( / | /{3}\s*) (\*) ///

POSSIBLY_DIVISION   = /// ^ /=?\s ///

# Other regexes.
HERECOMMENT_ILLEGAL = /\*\//

LINE_CONTINUER        = /// ^ \s* (?: , | \??\.(?![.\d]) | :: ) ///
LINE_CONTINUER_NO_DOT = /// ^ \s* (?: , | :: ) ///
CANT_PRECEDE_DOT_PROPERTY = [
  'RETURN', '(', '->', '=>', '=', 'CALL_START'
  'JSX_ELEMENT_NAME', 'JSX_START_TAG_END', 'JSX_ELEMENT_BODY_START'
]

STRING_INVALID_ESCAPE = ///
  ( (?:^|[^\\]) (?:\\\\)* )        # Make sure the escape isn’t escaped.
  \\ (
     ?: (0[0-7]|[1-7])             # octal escape
      | (x(?![\da-fA-F]{2}).{0,2}) # hex escape
      | (u\{(?![\da-fA-F]{1,}\})[^}]*\}?) # unicode code point escape
      | (u(?!\{|[\da-fA-F]{4}).{0,4}) # unicode escape
  )
///
REGEX_INVALID_ESCAPE = ///
  ( (?:^|[^\\]) (?:\\\\)* )        # Make sure the escape isn’t escaped.
  \\ (
     ?: (0[0-7])                   # octal escape
      | (x(?![\da-fA-F]{2}).{0,2}) # hex escape
      | (u\{(?![\da-fA-F]{1,}\})[^}]*\}?) # unicode code point escape
      | (u(?!\{|[\da-fA-F]{4}).{0,4}) # unicode escape
  )
///

UNICODE_CODE_POINT_ESCAPE = ///
  ( \\\\ )        # Make sure the escape isn’t escaped.
  |
  \\u\{ ( [\da-fA-F]+ ) \}
///g

LEADING_BLANK_LINE  = /^[^\n\S]*\n/
TRAILING_BLANK_LINE = /\n[^\n\S]*$/

TRAILING_SPACES     = /\s+$/

# Compound assignment tokens.
COMPOUND_ASSIGN = [
  '-=', '+=', '/=', '*=', '%=', '||=', '&&=', '?=', '<<=', '>>=', '>>>='
  '&=', '^=', '|=', '**=', '//=', '%%='
]

# Unary tokens.
UNARY = ['NEW', 'TYPEOF', 'DELETE', 'DO']

UNARY_MATH = ['!', '~']

# Bit-shifting tokens.
SHIFT = ['<<', '>>', '>>>']

# Comparison tokens.
COMPARE = ['==', '!=', '<', '>', '<=', '>=']

# Mathematical tokens.
MATH = ['*', '/', '%', '//', '%%']

# Relational tokens that are negatable with `not` prefix.
RELATION = ['IN', 'OF', 'INSTANCEOF']

# Boolean tokens.
BOOL = ['TRUE', 'FALSE']

# Tokens which could legitimately be invoked or indexed. An opening
# parentheses or bracket following these tokens will be recorded as the start
# of a function invocation or indexing operation.
CALLABLE  = ['IDENTIFIER', 'PROPERTY', ')', ']', '?', '@', 'THIS', 'SUPER']
INDEXABLE = CALLABLE.concat [
  'NUMBER', 'INFINITY', 'NAN', 'STRING', 'STRING_END', 'REGEX', 'REGEX_END'
  'BOOL', 'NULL', 'UNDEFINED', '}', '::'
]

# Tokens which a regular expression will never immediately follow (except spaced
# CALLABLEs in some cases), but which a division operator can.
#
# See: http://www-archive.mozilla.org/js/language/js20-2002-04/rationale/syntax.html#regular-expressions
NOT_REGEX = INDEXABLE.concat ['++', '--']

# Tokens that, when immediately preceding a `WHEN`, indicate that the `WHEN`
# occurs at the start of a line. We disambiguate these from trailing whens to
# avoid an ambiguity in the grammar.
LINE_BREAK = ['INDENT', 'OUTDENT', 'TERMINATOR']

# Additional indent in front of these is ignored.
INDENTABLE_CLOSERS = [')', '}', ']']
