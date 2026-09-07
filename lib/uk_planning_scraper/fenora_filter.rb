# frozen_string_literal: true
#
# lib/uk_planning_scraper/fenora_filter.rb
#
# Multi-layered relevance filter for Fenora sync.
#
# Only passes through planning applications that represent a genuine
# window, door, glazing, or joinery opportunity for a Fenora customer.
#
# Layers:
#   1. Hard exclusions — auto-reject telecoms masts, solar farms, etc.
#   2. Negative context — "windowless", "no windows", "remove windows"
#   3. Broad keyword gate — must contain at least one relevant term
#   4. Phrase scoring — strong phrases weighted much higher than weak ones
#   5. Action + object detection — "replace windows" > "windows"
#   6. Exclusion penalties — reduce score for irrelevant construction terms
#   7. Heritage / conservation weighting — listed buildings, sash, timber
#   8. Joinery material vocabulary — Accoya, oak, sapele, hardwood, etc.
#   9. Main-works classification — is the application primarily about windows/doors?
#  10. Quantity / scale signals — "all windows", "12 sash windows", etc.
#  11. Property type signals — house, bungalow, shopfront, church, etc.
#  12. Context boosters — extension, renovation, conversion, new build
#  13. Description position analysis — window/door terms at start = stronger
#
# Final classification:
#   :relevant    — strong window/door lead (score >= KEEP_THRESHOLD)
#   :secondary   — windows/doors present but part of larger project
#   :uncertain   — borderline, too vague to decide confidently
#   :irrelevant  — no meaningful window/door opportunity
#

require 'set'

module UKPlanningScraper
  module FenoraFilter
    KEEP_THRESHOLD = 10
    SECONDARY_THRESHOLD = 5
    UNCERTAIN_THRESHOLD = 3

    # ---- Layer 1: Hard exclusions — auto-reject regardless of score ----
    HARD_EXCLUSIONS = [
      /telecommunications?\s+(?:mast|pole|monopole|cabinet|equipment)/i,
      /solar\s+farm/i,
      /wind\s+(?:turbine|farm)/i,
      /\bsubstation\b/i,
      /pumping\s+station/i,
      /sewage\s+works/i,
      /landfill/i,
      /reservoir/i,
      /\bwind\s+turbine\b/i,
    ].freeze

    # ---- Layer 2: Negative context — reject or penalise ----
    # These mean a window/door word is being used in a non-opportunity context.
    NEGATIVE_CONTEXT_PATTERNS = [
      /windowless/i,
      /no\s+windows?/i,
      /remov(?:e|al|ing)\s+(?:all\s+)?(?:existing\s+)?windows?/i,
      /remov(?:e|al|ing)\s+(?:all\s+)?(?:existing\s+)?doors?/i,
      /windows?\s+(?:to\s+be\s+)?remov/i,
      /doors?\s+(?:to\s+be\s+)?remov/i,
      /board(?:ed|ing)\s+up\s+(?:windows|doors)/i,
      /brick\s+up\s+(?:windows|doors|openings)/i,
      /infill\s+(?:windows|doors|openings)/i,
    ].freeze

    # ---- Layer 3: Broad keyword gate ----
    # If none of these appear anywhere in description or address, reject immediately.
    # Uses regex word boundaries to avoid false matches like "sash" in "sashimi".
    GATE_REGEX = /
      \b(?:
        window(?:s)? | casement | sash(?:es)? | glazing | glazed | glass
        | double[\s-]*glaz(?:ing|ed)? | triple[\s-]*glaz(?:ing|ed)?
        | secondary[\s-]*glazing
        | rooflight | skylight | fenestration
        | door(?:s)? | entrance | front[\s-]*door | rear[\s-]*door
        | side[\s-]*door | patio[\s-]*door | french[\s-]*door
        | bifold | bi-fold | sliding[\s-]*door | folding[\s-]*door
        | stable[\s-]*door | external[\s-]*door | internal[\s-]*door
        | doorframe | door[\s-]*frame | door[\s-]*opening
        | joinery | timber[\s-]*window | timber[\s-]*door
        | wooden[\s-]*window | wooden[\s-]*door
        | aluminium[\s-]*window | aluminium[\s-]*door
        | upvc | u[\s-]*pvc | curtain[\s-]*wall
        | shopfront | shop[\s-]*front
        | dormer | oriel | lantern | mullion | transom
        | astragal | cill | sill
        | tilt[\s&-]*and[\s-]*turn
        | composite[\s-]*door | glazed[\s-]*door | pocket[\s-]*door
        | replacement[\s-]*units?
        | hardwood | softwood | accoya | sapele | meranti
        | bespoked? | made[\s-]*to[\s-]*measure
      )\b
    /ix.freeze

    # ---- Layer 4: Phrase scoring ----
    # Strong phrases get high scores; weak standalone terms get low scores.
    # Within each group, all matching patterns accumulate (different phrases
    # about different things should all count).
    STRONG_PHRASES = {
      /replacement\s+windows?/i => 10,
      /replacement\s+doors?/i => 10,
      /replace\s+windows?/i => 10,
      /replace\s+doors?/i => 10,
      /new\s+windows?/i => 10,
      /new\s+external\s+doors?/i => 10,
      /new\s+entrance\s+door/i => 10,
      /new\s+front[\s-]*door/i => 10,
      /new\s+rear[\s-]*door/i => 10,
      /new\s+patio[\s-]*door/i => 10,
      /replacement\s+timber\s+windows?/i => 12,
      /replacement\s+sash\s+windows?/i => 12,
      /replacement\s+casement\s+windows?/i => 12,
      /replacement\s+of\s+(?:all\s+)?(?:existing\s+)?(?:timber\s+)?sash\s+windows?/i => 14,
      /replacement\s+of\s+(?:all\s+)?(?:existing\s+)?(?:timber\s+)?casement\s+windows?/i => 14,
      /new\s+bifold\s+doors?/i => 10,
      /new\s+bi-fold\s+doors?/i => 10,
      /new\s+french[\s-]*doors?/i => 10,
      /new\s+sliding[\s-]*doors?/i => 10,
      /new\s+folding[\s-]*doors?/i => 10,
      /alterations?\s+to\s+windows?/i => 8,
      /alterations?\s+to\s+doors?/i => 8,
      /alterations?\s+to\s+fenestration/i => 8,
      /alterations?\s+to\s+(?:the\s+)?(?:front|rear|side|principal)\s+(?:elevation|facade)/i => 6,
      /replacement\s+glazing/i => 10,
      /secondary[\s-]*glazing/i => 10,
      /new\s+window\s+openings?/i => 8,
      /new\s+door\s+openings?/i => 8,
      /installation\s+of\s+(?:new\s+)?(?:windows|doors|glazing|bifold|bi-fold|french[\s-]*doors?|sliding[\s-]*doors?)/i => 10,
      /installation\s+of\s+(?:aluminium|timber|upvc|wooden|composite|oak|sapele|accoya)\s+(?:windows|doors)/i => 12,
      /replacement\s+of\s+(?:aluminium|timber|upvc|wooden|composite|oak|sapele|accoya)\s+(?:windows|doors)/i => 12,
      /replacement\s+of\s+(?:all\s+)?(?:windows|doors|sash|casement|glazing)/i => 10,
      /like[\s-]*for[\s-]*like\s+(?:replacement\s+)?(?:windows|doors|sash)/i => 10,
      /reinstatement\s+of\s+(?:windows|doors|sash|glazing)/i => 10,
      /restoration\s+of\s+(?:windows|doors|sash|glazing|joinery)/i => 10,
      /repair\s+(?:to|of)\s+(?:windows|doors|sash|glazing|joinery)/i => 8,
      /upgrade\s+(?:to|of)\s+(?:windows|doors|glazing)/i => 8,
      /shopfront\s+(?:replacement|new|refurb|alter)/i => 8,
      /curtain[\s-]*wall/i => 8,
      /replacement\s+units?/i => 8,
      /new\s+composite[\s-]*door/i => 10,
      /new\s+glazed[\s-]*door/i => 10,
      /new\s+stable[\s-]*door/i => 10,
      /new\s+pocket[\s-]*door/i => 8,
      /erection\s+of\s+(?:a\s+|one\s+|two\s+|\d+\s+)?(?:single|two|detached|semi|terraced|storey)?\s*(?:dwelling|house|home|bungalow|flat|apartment)/i => 6,
      /construction\s+of\s+(?:\d+\s+)?(?:new\s+)?(?:dwelling|house|home|bungalow|flat|apartment|residential)/i => 6,
    }.freeze

    MODERATE_PHRASES = {
      /sash\s+windows?/i => 6,
      /casement\s+windows?/i => 6,
      /bifold\s+doors?/i => 6,
      /bi-fold\s+doors?/i => 6,
      /french[\s-]*doors?/i => 6,
      /sliding[\s-]*doors?/i => 6,
      /patio[\s-]*doors?/i => 6,
      /stable[\s-]*door/i => 6,
      /entrance\s+door/i => 6,
      /front[\s-]*door/i => 6,
      /rear[\s-]*door/i => 5,
      /side[\s-]*door/i => 5,
      /external\s+doors?/i => 5,
      /internal\s+doors?/i => 3,
      /timber\s+windows?/i => 6,
      /timber\s+doors?/i => 6,
      /wooden\s+windows?/i => 6,
      /wooden\s+doors?/i => 6,
      /aluminium\s+windows?/i => 6,
      /aluminium\s+doors?/i => 6,
      /upvc\s+windows?/i => 5,
      /composite[\s-]*door/i => 6,
      /glazed[\s-]*door/i => 5,
      /pocket[\s-]*door/i => 4,
      /double[\s-]*glaz/i => 6,
      /triple[\s-]*glaz/i => 6,
      /rooflight/i => 5,
      /skylight/i => 5,
      /dormer\s+window/i => 5,
      /window\s+openings?/i => 5,
      /door\s+openings?/i => 5,
      /door\s+frames?/i => 4,
      /window\s+frames?/i => 4,
      /fenestration/i => 6,
      /joinery/i => 4,
      /shopfront/i => 5,
      /shop[\s-]*front/i => 5,
      /tilt[\s&-]*and[\s-]*turn/i => 5,
      /replacement\s+units?/i => 6,
    }.freeze

    WEAK_TERMS = {
      /\bwindows?\b/i => 2,
      /\bdoors?\b/i => 2,
      /\bglazing\b/i => 2,
      /\bglazed\b/i => 2,
      /\bglass\b/i => 1,
    }.freeze

    # ---- Layer 5: Action + object detection ----
    ACTIONS = %w[
      replace replacement install installation construct construction
      alter alteration refurbish refurbishment restore restoration
      reinstate reinstatement upgrade repair modify enlarge
      create form introduce remove relocate erect erecting
      convert conversion
    ].freeze

    OBJECTS = %w[
      window windows door doors glazing fenestration
      sash casement bifold bi-fold rooflight skylight joinery
      shopfront
    ].freeze

    # ---- Layer 6: Exclusion penalties ----
    # These reduce the score but don't auto-reject (a barn conversion with
    # replacement windows is still relevant).
    EXCLUSION_PATTERNS = {
      /demolition/i => -6,
      /demolish/i => -6,
      /highway|access\s+road/i => -5,
      /drainage|sewer/i => -4,
      /telecommunications?|telecoms?/i => -6,
      /solar\s+(?:panel|farm)/i => -6,
      /wind\s+(?:turbine|farm)/i => -6,
      /agricultural\s+(?:building|land|development)/i => -3,
      /car\s+park|parking/i => -4,
      /landscaping/i => -3,
      /tree\s+(?:works|removal|felling)/i => -5,
      /flood\s+defence/i => -5,
      /retaining\s+wall|boundary\s+wall/i => -4,
      /advertisement|signage/i => -5,
      /substation|electrical\s+substation/i => -6,
      /pumping\s+station/i => -5,
      /prior\s+approval/i => -4,
      /discharge\s+of\s+(?:conditions|condition)/i => -5,
      /non[-\s]?material\s+amendment/i => -5,
      /certificate\s+of\s+lawfulness/i => -4,
      /variation\s+of\s+condition/i => -4,
      /tpo|tree\s+preservation/i => -5,
      /prune|fell|crown/i => -5,
      /railway/i => -4,
      /bridge/i => -3,
      /industrial\s+plant/i => -4,
      /barn\s+conversion/i => -2,
      /change\s+of\s+use/i => -2,
    }.freeze

    # ---- Layer 7: Heritage / conservation weighting ----
    HERITAGE_PATTERNS = {
      /listed\s+building/i => 4,
      /\bgrade\s+[ivx]+\b/i => 4,
      /conservation\s+area/i => 3,
      /heritage/i => 3,
      /historic/i => 2,
      /traditional/i => 2,
      /period\s+property/i => 3,
      /original\s+windows?/i => 4,
      /original\s+sash/i => 4,
      /timber\s+sash/i => 4,
      /sliding\s+sash/i => 4,
      /box\s+sash/i => 4,
      /spiral\s+sash/i => 3,
      /mock\s+sash/i => 3,
      /flush\s+casement/i => 3,
      /french\s+casement/i => 3,
      /bay\s+windows?/i => 3,
      /bow\s+windows?/i => 3,
      /like[\s-]*for[\s-]*like/i => 3,
      /reinstatement/i => 3,
    }.freeze

    # ---- Layer 8: Joinery material vocabulary ----
    MATERIAL_PATTERNS = {
      /\btimber\b/i => 3,
      /\bhardwood\b/i => 3,
      /\bsoftwood\b/i => 2,
      /\baccoya\b/i => 4,
      /\boak\b/i => 3,
      /\bsapele\b/i => 3,
      /\bredwood\b/i => 2,
      /\bmeranti\b/i => 3,
      /\baluminium\b/i => 3,
      /\bupvc\b|\bu[\s-]*pvc\b/i => 2,
      /\bwooden\b/i => 3,
      /\bbespoke\b/i => 3,
      /made[\s-]*to[\s-]*measure/i => 3,
      /\bcomposite\b/i => 2,
    }.freeze

    # ---- Layer 9: Main-works indicators ----
    # If the description starts with window/door terms, the main work is
    # likely windows/doors. If they appear at the end of a long description,
    # they're probably secondary.
    MAIN_WORKS_INDICATORS = %w[
      replacement replace new installation install
      alterations alteration restoration reinstatement
      erection erection of
    ].freeze

    # ---- Layer 10: Quantity / scale signals ----
    QUANTITY_PATTERNS = {
      /\b(\d+)\s*(?:sash|casement)?\s*windows?/i => :count,
      /\b(\d+)\s*doors?/i => :count,
      /\ball\s+(?:windows|doors|external\s+doors|sash|casement)/i => :all,
      /\bthroughout\b/i => :all,
      /\bseveral\s+(?:windows|doors)/i => :several,
      /\bmultiple\s+(?:windows|doors)/i => :several,
      /\bfront\s+elevation/i => :elevation,
      /\brear\s+elevation/i => :elevation,
      /\bprincipal\s+elevation/i => :elevation,
      /\bside\s+elevation/i => :elevation,
      /\bground\s+floor/i => :floor,
      /\bfirst\s+floor/i => :floor,
      /\bupper\s+floors?/i => :floor,
      /\b(?:front|rear|side)\s+facade/i => :elevation,
    }.freeze

    # ---- Layer 11: Property type signals ----
    PROPERTY_TYPE_POSITIVE = {
      /\bhouse\b/i => 2,
      /\bbungalow\b/i => 2,
      /\bcottage\b/i => 2,
      /\btownhouse\b/i => 2,
      /\bflat\b/i => 1,
      /\bapartment\b/i => 1,
      /\blisted\s+building\b/i => 3,
      /\bperiod\s+property\b/i => 2,
      /\bcommercial\s+(?:building|premises|unit)\b/i => 2,
      /\bshopfront\b|\bshop[\s-]*front\b/i => 3,
      /\boffice\b/i => 1,
      /\bhotel\b/i => 2,
      /\bschool\b/i => 2,
      /\bchurch\b/i => 2,
      /\bpublic\s+building\b/i => 2,
      /\bchapel\b/i => 2,
      /\bpub\b/i => 1,
      /\brestaurant\b/i => 1,
      /\bcafe\b/i => 1,
      /\bshop\b/i => 1,
    }.freeze

    PROPERTY_TYPE_NEGATIVE = {
      /\brailway\b/i => -3,
      /\bbridge\b/i => -2,
      /\bindustrial\s+plant\b/i => -3,
      /\blandfill\b/i => -4,
      /\breservoir\b/i => -4,
      /\bsewage\s+works\b/i => -4,
      /\bagricultural\s+field\b/i => -2,
    }.freeze

    # ---- Layer 12: Context boosters ----
    # These add a small score when combined with window/door terms.
    CONTEXT_BOOSTERS = {
      /\bextension\b/i => 2,
      /\brenovation\b/i => 2,
      /\brefurbishment\b/i => 2,
      /\brefurbish\b/i => 2,
      /\bconversion\b/i => 2,
      /\bnew\s+build\b/i => 2,
      /\balteration/i => 2,
      /\bexternal\s+alterations?/i => 2,
      /\binternal\s+alterations?/i => 1,
      /\bredevelopment\b/i => 2,
      /\bimprovement\s+works?/i => 1,
    }.freeze

    module_function

    # Returns a hash with:
    #   :keep       => boolean
    #   :category   => :relevant | :secondary | :uncertain | :irrelevant
    #   :score      => integer
    #   :reason     => string
    #   :signals    => array of matched signals
    def evaluate(description, address = nil, status = nil)
      text = [description, address].compact.join(' ').to_s
      return reject_result('Empty description') if text.strip.empty?

      # Layer 1: Hard exclusions
      HARD_EXCLUSIONS.each do |rx|
        return reject_result("Hard exclusion: #{rx.source}") if rx.match?(text)
      end

      # Layer 2: Negative context — auto-reject
      NEGATIVE_CONTEXT_PATTERNS.each do |rx|
        return reject_result("Negative context: #{rx.source}") if rx.match?(text)
      end

      # Layer 3: Gate — must contain at least one relevant term
      gate_hit = GATE_REGEX.match?(text)
      return reject_result('No relevant window/door terms found') unless gate_hit

      score = 0
      signals = []

      # Layer 4: Phrase scoring
      STRONG_PHRASES.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} strong: #{rx.source}"
        end
      end

      MODERATE_PHRASES.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} moderate: #{rx.source}"
        end
      end

      WEAK_TERMS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} weak: #{rx.source}"
        end
      end

      # Layer 5: Action + object detection
      action_score = score_action_object(text)
      if action_score > 0
        score += action_score
        signals << "+#{action_score} action+object"
      end

      # Layer 6: Exclusion penalties
      EXCLUSION_PATTERNS.each do |rx, penalty|
        if rx.match?(text)
          score += penalty
          signals << "#{penalty} exclusion: #{rx.source}"
        end
      end

      # Layer 7: Heritage weighting
      HERITAGE_PATTERNS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} heritage: #{rx.source}"
        end
      end

      # Layer 8: Joinery material vocabulary
      MATERIAL_PATTERNS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} material: #{rx.source}"
        end
      end

      # Layer 9: Main-works classification
      main_works = main_works?(text)
      if main_works
        score += 5
        signals << '+5 main-works'
      end

      # Layer 10: Quantity / scale
      qty_bonus = quantity_bonus(text)
      if qty_bonus > 0
        score += qty_bonus
        signals << "+#{qty_bonus} quantity/scale"
      end

      # Layer 11: Property type signals
      PROPERTY_TYPE_POSITIVE.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} property: #{rx.source}"
        end
      end

      PROPERTY_TYPE_NEGATIVE.each do |rx, penalty|
        if rx.match?(text)
          score += penalty
          signals << "#{penalty} neg-property: #{rx.source}"
        end
      end

      # Layer 12: Context boosters
      CONTEXT_BOOSTERS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} context: #{rx.source}"
        end
      end

      # Layer 13: Description position analysis
      position_bonus = position_analysis(text)
      if position_bonus > 0
        score += position_bonus
        signals << "+#{position_bonus} early-position"
      end

      # Status penalty
      if status && status.match?(/withdrawn|refused|invalid/i)
        score -= 8
        signals << '-8 withdrawn/refused/invalid status'
      end

      # Classification
      category = if score >= KEEP_THRESHOLD
        :relevant
      elsif score >= SECONDARY_THRESHOLD
        :secondary
      elsif score >= UNCERTAIN_THRESHOLD
        :uncertain
      else
        :irrelevant
      end

      keep = category == :relevant || category == :secondary || category == :uncertain

      {
        keep: keep,
        category: category,
        score: score,
        reason: signals.empty? ? 'No signals' : signals.join('; '),
        signals: signals,
      }
    end

    def score_action_object(text)
      words = text.downcase.scan(/[a-z]+/)
      word_set = words.to_set

      has_action = ACTIONS.any? { |a| word_set.include?(a) }
      has_object = OBJECTS.any? { |o| word_set.include?(o) }

      return 0 unless has_action && has_object

      # Check for action+object proximity (within ~60 chars)
      ACTIONS.each do |action|
        OBJECTS.each do |object|
          if text.match?(/#{action}.{0,60}#{object}/i) || text.match?(/#{object}.{0,60}#{action}/i)
            return 6
          end
        end
      end
      3
    end

    def main_works?(text)
      # Check if the first ~100 chars mention window/door terms
      # alongside a main-works action verb
      prefix = text[0..100].downcase
      GATE_REGEX.match?(prefix) &&
        MAIN_WORKS_INDICATORS.any? { |a| prefix.include?(a) }
    end

    def quantity_bonus(text)
      bonus = 0
      QUANTITY_PATTERNS.each do |rx, type|
        if rx.match?(text)
          case type
          when :count
            m = text.match(rx)
            n = m[1].to_i
            bonus += n >= 5 ? 6 : 3
          when :all
            bonus += 5
          when :several
            bonus += 3
          when :elevation
            bonus += 2
          when :floor
            bonus += 1
          end
        end
      end
      bonus
    end

    # Layer 13: Description position analysis
    # Window/door terms appearing in the first third of the description
    # indicate the primary work. Terms buried at the end suggest secondary.
    def position_analysis(text)
      return 0 if text.length < 30
      third = (text.length / 3.0).round
      prefix = text[0..third]

      # Strong: gate term in first 20% of text
      first_fifth = text[0..(text.length / 5.0).round]
      return 4 if GATE_REGEX.match?(first_fifth)

      # Moderate: gate term in first third
      return 2 if GATE_REGEX.match?(prefix)

      0
    end

    def reject_result(reason)
      {
        keep: false,
        category: :irrelevant,
        score: 0,
        reason: reason,
        signals: [],
      }
    end

    # Batch filter: takes array of row hashes, returns [kept, rejected, stats]
    def filter_rows(rows)
      kept = []
      rejected = []
      stats = { relevant: 0, secondary: 0, uncertain: 0, irrelevant: 0 }

      rows.each do |row|
        result = evaluate(
          row['description'] || row[:description],
          row['address'] || row[:address],
          row['status'] || row[:status],
        )

        stats[result[:category]] += 1

        if result[:keep]
          enriched = row.is_a?(Hash) ? row.dup : row.to_h
          if enriched.is_a?(Hash) && !enriched.key?('fenora_score')
            enriched['fenora_score'] = result[:score]
            enriched['fenora_category'] = result[:category].to_s
          end
          kept << enriched
        else
          rejected << { row: row, reason: result[:reason], score: result[:score] }
        end
      end

      [kept, rejected, stats]
    end
  end
end
