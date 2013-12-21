define [
  'underscore'
  'jquery'
], (_, $) ->


  # There is a bit of ugliness with the `data-js-polyfill-rule-#{ruleName}` attributes.
  # Here are notes for an explanation:

  # - Once a rule is understood do not continue for that rule (content, display, counter-increment, etc)
  # rules:
  #   content: target-counter() # May resolve later, keep trying
  #   content: foo() # Cannot resolve; do not use
  #   content: 'Hi'  # Can resolve
  #   move-to: bucket # Non idempotent change; do NOT re-run
  #   x-tag-name:
  #   counter-increment: # state change

  # Each rule returns:

  #   falsy: Did not understand, try another rule (walk up the cascade)
  #   truthy: Understood and can be run again
  #   'RULE_COMPLETED': Understood and CANNOT RERUN (mark with a class)

  # Example: FixedPoint applying the ContentPlugin:
  #   - loop over all rules
  #     - if rule returns truthy then add .js-pending-content and add 'content' to the keys to ignore
  #     - if rule returns 'RULE_COMPLETED' add .js-completed-content and add 'content' to the keys to ignore
  #   - if any return truthy then **after** the loop add .js-calculating-content (after is important for move-to)



  return class FixedPointRunner
    # plugins: []
    # $root: jQuery(...)
    # autogenClasses: {}
    # functions: {}
    # rules: {}

    constructor: (@$root, @plugins, @autogenClasses) ->
      @squirreledEnv = {} # id -> env map. Needs to persist across runs because the target may occur **after** the element that looks it up
      @functions = {}
      # Rules must be evaluated in Plugin order.
      # For example, `counter-increment: ctr` must run before `string-set: counter(ctr)`
      @rules = []

      for plugin in @plugins
        @functions[funcName] = func for funcName, func of plugin.functions
        @rules.push({name:ruleName, func:ruleFunc}) for ruleName, ruleFunc of plugin.rules


    lookupAutogenClass: ($node) ->
      classes = $node.attr('class').split(' ')
      foundClass = null
      for cls in classes
        if /^js-polyfill-autoclass-/.test(cls)
          console.error 'BUG: Multiple autogen classes. Canonicalize first!' if foundClass and @autogenClasses[cls]

          foundClass ?= @autogenClasses[cls]
          console.error 'BUG: Did not find autogenerated class in autoClasses' if not foundClass
      return foundClass


    tick: ($interesting) ->
      somethingChanged = 0
      # env is a LessEnv (passed to `lessNode.eval()`) so it needs to contain a .state and .helpers
      env =
        state: {} # plugins will add `counters`, `strings`, `buckets`, etc
        helpers:
          # $context: null
          interestingByHref: (href) =>
            console.error 'BUG: href must start with a # character' if '#' != href[0]
            id = href.substring(1)
            console.error 'BUG: id was not marked and squirreled before being looked up' if not @squirreledEnv[id]
            return @squirreledEnv[id]
          markInterestingByHref: (href) =>
            console.error 'BUG: href must start with a # character' if '#' != href[0]
            id = href.substring(1)
            wasAlreadyMarked = !! @squirreledEnv[id]
            if not wasAlreadyMarked
              # Mark that this node will need to squirrel its env
              $target = @$root.find("##{id}")
              if $target[0]
                # Only flag if the target exists
                somethingChanged += 1
                $target.addClass('js-polyfill-interesting js-polyfill-target')
            return !wasAlreadyMarked
          didSomthingNonIdempotent: (msg) ->
            somethingChanged += 1

      for node in $interesting
        $node = $(node)

        env.helpers.$context = $node
        autoClass = @lookupAutogenClass($node)
        # Check if the node has an autogenerated class on it.
        # It may just be an "interesting" target.
        if autoClass
          autogenRules = autoClass.rules

          understoodRules = {} # ruleName -> true
          for rule in @rules
            # Loop through the rules in reverse order.
            # Once a rule is "understood" then we can skip processing other rules
            ruleFilter = (r) ->
              # As of https://github.com/less/less.js/commit/ebdadaedac2ba2be377ae190060f9ca8086253a4
              # a Rule name is an Array so join them together.
              # This is why less.js is currently pinned to #4fd970426662600ecb41bced71206aece5a88ee4
              name = r.name
              name = name.join('') if name instanceof Array
              return rule.name == name

            for autogenRule in _.filter(autogenRules, ruleFilter).reverse()

              ruleName = autogenRule.name
              # As of https://github.com/less/less.js/commit/ebdadaedac2ba2be377ae190060f9ca8086253a4
              # a Rule name is an Array so join them together.
              # This is why less.js is currently pinned to #4fd970426662600ecb41bced71206aece5a88ee4
              ruleName = ruleName.join('') if ruleName instanceof Array

              ruleValNode = autogenRule.value
              continue if not ruleName # Skip comments and such

              # Skip because the rule has already been understood (plugin decides what that means)
              if ruleName of understoodRules
                continue

              # Skip because the rule has already performed some non-idempotent action
              if $node.is("[data-js-polyfill-rule-#{ruleName}='completed']")
                continue

              # update the env
              understood = rule.func(env, ruleValNode)
              if understood
                understoodRules[ruleName] = true
                $node.attr("data-js-polyfill-rule-#{ruleName}", 'evaluated')
                if understood == 'RULE_COMPLETED'
                  somethingChanged += 1
                  $node.attr("data-js-polyfill-rule-#{ruleName}", 'completed')
              break

          for ruleName of understoodRules
            if not $node.attr("data-js-polyfill-rule-#{ruleName}")
              $node.attr("data-js-polyfill-rule-#{ruleName}", 'pending')


        if $node.is('.js-polyfill-target')
          # Keep the helper functions (targetText uses them) but not the state
          targetEnv =
            helpers: _.clone(env.helpers)
            state: JSON.parse(JSON.stringify(_.omit(env.state, 'buckets'))) # Perform a deep clone
          targetEnv.helpers.$context = $node
          @squirreledEnv[$node.attr('id')] = targetEnv

      return somethingChanged


    setUp: () ->
      # Register all the functions with less.tree.functions
      for funcName, func of @functions
        # Wrap all the functions and attach them to `less.tree.functions`
        wrapper = (funcName, func) -> () ->
          ret = func.apply(@, [@env, arguments...])
          # If ret is null or undefined then ('' is OK) mark that is was not evaluated
          # by returning the original less.tree.Call
          if not ret?
            return new less.tree.Call(funcName, _.toArray(arguments))
          else if ret instanceof Array
            # HACK: Use the Less AST so we do not need to include 1 file just to not reuse a similar class
            return new less.tree.ArrayTreeNode(ret)
          else if _.isString(ret)
            # Just being a good LessCSS user. Could have just returned Anonymous
            return new less.tree.Quoted("'#{ret}'", ret)
          else if _.isNumber(ret)
            # Just being a good LessCSS user. Could have just returned Anonymous
            return new less.tree.Dimension(ret)
          else
            return new less.tree.Anonymous(ret)

        less.tree.functions[funcName] = wrapper(funcName, func)


    # Detach all the functions so `lessNode.toCSS()` will generate the CSS
    done: () ->
      for funcName of @functions
        delete less.tree.functions[funcName]
      # TODO: remove all `.js-polyfill-interesting, .js-polyfill-evaluated, .js-polyfill-target` classes

      discardedClasses = [
        'js-polyfill-evaluated'
        'js-polyfill-interesting'
        'js-polyfill-target'
      ]
      # add '.' and ',' for the find, but a space for the classes to remove
      # @$root.find(".#{discardedClasses.join(',.')}").removeClass(discardedClasses.join(' '))

    run: () ->
      @setUp()

      # Initially, interesting nodes are all the nodes that have an AutogenClass
      $interesting = @$root.find('.js-polyfill-autoclass, .js-polyfill-interesting')
      $interesting.addClass('js-polyfill-interesting')

      ticks = 0
      console.log("DEBUG: FixedPointRunner TICK #{ticks}")
      while changes = @tick($interesting) # keep looping while somethingChanged
        ticks++
        console.log("DEBUG: FixedPointRunner TICK #{ticks}. changes: #{changes}")
        $interesting = @$root.find('.js-polyfill-interesting')

      @done()
