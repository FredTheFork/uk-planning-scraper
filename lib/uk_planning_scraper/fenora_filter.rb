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
#   1. Broad keyword gate — must contain at least one relevant term
#   2. Phrase scoring — strong phrases weighted much higher than weak ones
#   3. Action + object detection — "replace windows" > "windows"
#   4. Exclusion penalties — reduce score for irrelevant construction terms
#   5. Heritage / conservation weighting — listed buildings, sash, timber
#   6. Main-works classification — is the application primarily about windows/doors?
#   7. Quantity / scale signals — "all windows", "12 sash windows", etc.
#
# Final classification:
#   :relevant    — strong window/door lead (score >= KEEP_THRESHOLD)
#   :secondary   — windows/doors present but part of larger project
#   :irrelevant  — no meaningful window/door opportunity
#

require 'set'

module UKPlanningScraper
  module FenoraFilter
    KEEP_THRESHOLD = 10
    SECONDARY_THRESHOLD = 5

    # ---- Layer 1: Broad keyword gate ----
    # If none of these appear anywhere in description or address, reject immediately.
    GATE_TERMS = %w[
      window windows casement sash glazing glazed
      double-glazing triple-glazing secondary-glazing
      rooflight skylight fenestration
      door doors entrance front-door rear-door side-door
      patio french bifold bi-fold sliding-doors
      stable-door external-doors doorframe
      joinery timber-windows timber-doors
      wooden-windows wooden-doors
      aluminium-windows aluminium-doors
      upvc upvc-windows
      curtain-walling shopfront
      dormer oriel lantern mullion transom
      astragal cill sill
    ].freeze

    # ---- Layer 2: Phrase scoring ----
    # Strong phrases get high scores; weak standalone terms get low scores.
    STRONG_PHRASES = {
      /replacement\s+windows?/i => 10,
      /replacement\s+doors?/i => 10,
      /replace\s+windows?/i => 10,
      /replace\s+doors?/i => 10,
      /new\s+windows?/i => 10,
      /new\s+external\s+doors?/i => 10,
      /replacement\s+timber\s+windows?/i => 12,
      /replacement\s+sash\s+windows?/i => 12,
      /replacement\s+casement\s+windows?/i => 12,
      /new\s+bifold\s+doors?/i => 10,
      /new\s+bi-fold\s+doors?/i => 10,
      /new\s+french\s+doors?/i => 10,
      /new\s+sliding\s+doors?/i => 10,
      /new\s+entrance\s+door/i => 10,
      /alterations?\s+to\s+windows?/i => 8,
      /alterations?\s+to\s+doors?/i => 8,
      /alterations?\s+to\s+fenestration/i => 8,
      /replacement\s+glazing/i => 10,
      /secondary\s+glazing/i => 10,
      /new\s+window\s+openings?/i => 8,
      /new\s+door\s+openings?/i => 8,
      /installation\s+of\s+(?:new\s+)?(?:windows|doors|glazing|bifold|bi-fold|french\s+doors|sliding\s+doors)/i => 10,
      /replacement\s+of\s+(?:all\s+)?(?:windows|doors|sash|casement|glazing)/i => 10,
      /installation\s+of\s+(?:aluminium|timber|upvc|wooden)\s+(?:windows|doors)/i => 12,
      /replacement\s+of\s+(?:aluminium|timber|upvc|wooden)\s+(?:windows|doors)/i => 12,
      /like-for-like\s+(?:replacement\s+)?(?:windows|doors|sash)/i => 10,
      /reinstatement\s+of\s+(?:windows|doors|sash|glazing)/i => 10,
      /restoration\s+of\s+(?:windows|doors|sash|glazing|joinery)/i => 10,
      /shopfront\s+(?:replacement|new|refurb|alter)/i => 8,
      /curtain\s+walling/i => 8,
    }.freeze

    MODERATE_PHRASES = {
      /sash\s+windows?/i => 6,
      /casement\s+windows?/i => 6,
      /bifold\s+doors?/i => 6,
      /bi-fold\s+doors?/i => 6,
      /french\s+doors?/i => 6,
      /sliding\s+doors?/i => 6,
      /patio\s+doors?/i => 6,
      /stable\s+door/i => 6,
      /entrance\s+door/i => 6,
      /external\s+doors?/i => 5,
      /internal\s+doors?/i => 3,
      /timber\s+windows?/i => 6,
      /timber\s+doors?/i => 6,
      /wooden\s+windows?/i => 6,
      /wooden\s+doors?/i => 6,
      /aluminium\s+windows?/i => 6,
      /aluminium\s+doors?/i => 6,
      /upvc\s+windows?/i => 5,
      /double\s+glaz/i => 6,
      /triple\s+glaz/i => 6,
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
    }.freeze

    WEAK_TERMS = {
      /\bwindows?\b/i => 2,
      /\bdoors?\b/i => 2,
      /\bglazing\b/i => 2,
      /\bglazed\b/i => 2,
    }.freeze

    # ---- Layer 3: Action + object detection ----
    ACTIONS = %w[
      replace replacement install installation construct construction
      alter alteration refurbish refurbishment restore restoration
      reinstate reinstatement upgrade repair modify enlarge
      create form introduce remove relocate
    ].freeze

    OBJECTS = %w[
      window windows door doors glazing fenestration
      sash casement bifold bi-fold rooflight skylight joinery
    ].freeze

    # ---- Layer 4: Exclusion penalties ----
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
    }.freeze

    # ---- Layer 5: Heritage / conservation weighting ----
    HERITAGE_PATTERNS = {
      /listed\s+building/i => 4,
      /\bgrade\s+[i]+\b/i => 4,
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
    }.freeze

    # ---- Layer 6: Main-works indicators ----
    # If the description starts with window/door terms, the main work is
    # likely windows/doors. If they appear at the end of a long description,
    # they're probably secondary.
    MAIN_WORKS_INDICATORS = %w[
      replacement replace new installation install
      alterations alteration restoration reinstatement
    ].freeze

    # ---- Layer 7: Quantity / scale signals ----
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
    }.freeze

    # Hard exclusions — auto-reject regardless of score
    HARD_EXCLUSIONS = [
      /telecommunications?\s+(?:mast|pole|monopole)/i,
      /solar\s+farm/i,
      /wind\s+farm/i,
      /substation/i,
      /pumping\s+station/i,
      /sewage\s+works/i,
      /landfill/i,
      /reservoir/i,
      / Advertisement consent only/i,
    ].freeze

    module_function

    # Returns a hash with:
    #   :keep       => boolean
    #   :category   => :relevant | :secondary | :irrelevant
    #   :score      => integer
    #   :reason     => string
    #   :signals    => array of matched signals
    def evaluate(description, address = nil, status = nil)
      text = [description, address].compact.join(' ').to_s
      return reject_result('Empty description') if text.strip.empty?

      # Hard exclusions
      HARD_EXCLUSIONS.each do |rx|
        return reject_result("Hard exclusion: #{rx.source}") if rx.match?(text)
      end

      # Layer 1: Gate — must contain at least one relevant term
      gate_hit = GATE_TERMS.any? { |t| text.downcase.include?(t) }
      return reject_result('No relevant window/door terms found') unless gate_hit

      score = 0
      signals = []

      # Layer 2: Phrase scoring
      STRONG_PHRASES.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} strong phrase: #{rx.source}"
        end
      end

      MODERATE_PHRASES.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} moderate phrase: #{rx.source}"
        end
      end

      WEAK_TERMS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} weak term: #{rx.source}"
        end
      end

      # Layer 3: Action + object detection
      action_score = score_action_object(text)
      if action_score > 0
        score += action_score
        signals << "+#{action_score} action+object"
      end

      # Layer 4: Exclusion penalties
      EXCLUSION_PATTERNS.each do |rx, penalty|
        if rx.match?(text)
          score += penalty
          signals << "#{penalty} exclusion: #{rx.source}"
        end
      end

      # Layer 5: Heritage weighting
      HERITAGE_PATTERNS.each do |rx, pts|
        if rx.match?(text)
          score += pts
          signals << "+#{pts} heritage: #{rx.source}"
        end
      end

      # Layer 6: Main-works classification
      main_works = main_works?(text)
      if main_works
        score += 5
        signals << '+5 main-works indicator'
      end

      # Layer 7: Quantity / scale
      qty_bonus = quantity_bonus(text)
      if qty_bonus > 0
        score += qty_bonus
        signals << "+#{qty_bonus} quantity/scale"
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
      else
        :irrelevant
      end

      keep = category != :irrelevant

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

      has_action = ACTIONS.any? { |a| word_set.include?(a) || text.downcase.include?(a) }
      has_object = OBJECTS.any? { |o| word_set.include?(o) || text.downcase.include?(o) }

      return 0 unless has_action && has_object

      # Check for action+object proximity (within ~5 words)
      ACTIONS.each do |action|
        OBJECTS.each do |object|
          if text.match?(/#{action}.*{0,60}#{object}/i) || text.match?(/#{object}.*{0,60}#{action}/i)
            return 6
          end
        end
      end
      3
    end

    def main_works?(text)
      # Check if the first ~80 chars mention window/door terms
      prefix = text[0..80].downcase
      GATE_TERMS.any? { |t| prefix.include?(t) } &&
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

    def reject_result(reason)
      {
        keep: false,
        category: :irrelevant,
        score: 0,
        reason: reason,
        signals: [],
      }
    end

    # Batch filter: takes array of row hashes, returns [kept, rejected]
    def filter_rows(rows)
      kept = []
      rejected = []
      stats = { relevant: 0, secondary: 0, irrelevant: 0 }

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
