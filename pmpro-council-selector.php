<?php
/*
Plugin Name: PMPro Council Selector
Description: Adds dynamic council selection to Paid Memberships Pro checkout and filters user access based on chosen councils.
Version: 1.0
Author: Noel
*/

// Stop direct access
defined('ABSPATH') || exit;

/**
 * STEP A: Add the councils array
 */
$councils = [
    'Aberdeen' => 'aberdeen',
    'Aberdeenshire' => 'aberdeenshire',
    'Adur' => 'adur',
    'Allerdale' => 'allerdale',
    'Amber Valley' => 'amber-valley',
    'Angus' => 'angus',
    'Mid and East Antrim' => 'mid-and-east-antrim',
    'Argyll & Bute' => 'argyll-bute',
    'Armagh Banbridge and Craigavon' => 'armagh-banbridge-craigavon',
    'Arun' => 'arun',
    'Ashfield' => 'ashfield',
    'Ashford' => 'ashford',
    'Aylesbury Vale' => 'aylesbury-vale',
    'Babergh' => 'babergh',
    'Barking and Dagenham' => 'barking-dagenham',
    'Barnet' => 'barnet',
    'Barnsley' => 'barnsley',
    'Barrow-in-Furness' => 'barrow-in-furness',
    'Basildon' => 'basildon',
    'Basingstoke and Deane' => 'basingstoke-deane',
    'Bassetlaw' => 'bassetlaw',
    'Bath and North East Somerset' => 'bath-and-north-east-somerset',
    'Bedford' => 'bedford',
    'Belfast' => 'belfast',
    'Bexley' => 'bexley',
    'Birmingham' => 'birmingham',
    'Blaby' => 'blaby',
    'Blackburn with Darwen' => 'blackburn-darwen',
    'Blackpool' => 'blackpool',
    'Blaenau Gwent' => 'blaenau-gwent',
    'Bolsover' => 'bolsover',
    'Bolton' => 'bolton',
    'Boston' => 'boston',
    'Bournemouth Christchurch and Poole' => 'bournemouth-christchurch-poole',
    'Bracknell Forest' => 'bracknell-forest',
    'Bradford' => 'bradford',
    'Braintree' => 'braintree',
    'Breckland' => 'breckland',
    'Brent' => 'brent',
    'Brentwood' => 'brentwood',
    'Bridgend' => 'bridgend',
    'Brighton and Hove' => 'brighton-hove',
    'Bristol' => 'bristol',
    'Broadland' => 'broadland',
    'Bromley' => 'bromley',
    'Bromsgrove' => 'bromsgrove',
    'Broxbourne' => 'broxbourne',
    'Broxtowe' => 'broxtowe',
    'Burnley' => 'burnley',
    'Bury' => 'bury',
    'Caerphilly' => 'caerphilly',
    'Calderdale' => 'calderdale',
    'Cambridge' => 'cambridge',
    'Camden' => 'camden',
    'Cannock Chase' => 'cannock-chase',
    'Canterbury' => 'canterbury',
    'Cardiff' => 'cardiff',
    'Carlisle' => 'carlisle',
    'Carmarthenshire' => 'carmarthenshire',
    'Causeway Coast' => 'causeway-coast',
    'Castle Point' => 'castle-point',
    'Central Bedfordshire' => 'central-bedfordshire',
    'Ceredigion' => 'ceredigion',
    'Charnwood' => 'charnwood',
    'Chelmsford' => 'chelmsford',
    'Cheltenham' => 'cheltenham',
    'Cherwell' => 'cherwell',
    'Cheshire East' => 'cheshire-east',
    'Cheshire West and Chester' => 'cheshire-west-and-chester',
    'Chesterfield' => 'chesterfield',
    'Chichester' => 'chichester',
    'Chiltern' => 'chiltern',
    'Chorley' => 'chorley',
    'Clackmannanshire' => 'clackmannanshire',
    'Colchester' => 'colchester',
    'Comhairle nan Eilean Siar' => 'comhairle-nan-eilean-siar',
    'Conwy' => 'conwy',
    'Copeland' => 'copeland',
    'Corby' => 'corby',
    'Cornwall' => 'cornwall',
    'Cotswold' => 'cotswold',
    'Coventry' => 'coventry',
    'Craven' => 'craven',
    'Crawley' => 'crawley',
    'Croydon' => 'croydon',
    'Dacorum' => 'dacorum',
    'Darlington' => 'darlington',
    'Dartford' => 'dartford',
    'Denbighshire' => 'denbighshire',
    'Derby' => 'derby',
    'Derry City and Strabane' => 'derry-city-and-strabane',
    'Derbyshire Dales' => 'derbyshire-dales',
    'Doncaster' => 'doncaster',
    'Dorset' => 'dorset',
    'Dover' => 'dover',
    'Dudley' => 'dudley',
    'Dumfries and Galloway' => 'dumfries-and-galloway',
    'Dundee' => 'dundee',
    'Durham' => 'durham',
    'Ealing' => 'ealing',
    'East Ayrshire' => 'east-ayrshire',
    'East Cambridgeshire' => 'east-cambridgeshire',
    'East Devon' => 'east-devon',
    'East Dunbartonshire' => 'east-dunbartonshire',
    'East Hampshire' => 'east-hampshire',
    'East Hertfordshire' => 'east-hertfordshire',
    'East Lindsey' => 'east-lindsey',
    'East Lothian' => 'east-lothian',
    'East Northamptonshire' => 'east-northamptonshire',
    'East Renfrewshire' => 'east-renfrewshire',
    'East Riding of Yorkshire' => 'east-riding-of-yorkshire',
    'East Staffordshire' => 'east-staffordshire',
    'East Suffolk' => 'east-suffolk',
    'Eastbourne' => 'eastbourne',
    'Eastleigh' => 'eastleigh',
    'Edinburgh' => 'edinburgh',
    'Elmbridge' => 'elmbridge',
    'Enfield' => 'enfield',
    'Epsom and Ewell' => 'epsom-and-ewell',
    'Epping Forest' => 'epping-forest',
    'Erewash' => 'erewash',
    'Exeter' => 'exeter',
    'Falkirk' => 'falkirk',
    'Fareham' => 'fareham',
    'Fenland' => 'fenland',
    'Fermanagh and Omagh' => 'fermanagh-and-omagh',
    'Fife' => 'fife',
    'Flintshire' => 'flintshire',
    'Folkestone & Hythe' => 'folkestone-hythe',
    'Forest of Dean' => 'forest-of-dean',
    'Fylde' => 'fylde',
    'Gateshead' => 'gateshead',
    'Gedling' => 'gedling',
    'Glasgow' => 'glasgow',
    'Gloucester' => 'gloucester',
    'Gosport' => 'gosport',
    'Gravesham' => 'gravesham',
    'Great Yarmouth' => 'great-yarmouth',
    'Greater Manchester' => 'greater-manchester',
    'Greenwich' => 'greenwich',
    'Guildford' => 'guildford',
    'Gwynedd' => 'gwynedd',
    'Hackney' => 'hackney',
    'Halton' => 'halton',
    'Hambleton' => 'hambleton',
    'Hammersmith & Fulham' => 'hammersmith-fulham',
    'Harborough' => 'harborough',
    'Haringey' => 'haringey',
    'Harlow' => 'harlow',
    'Harrow' => 'harrow',
    'Harrogate' => 'harrogate',
    'Hart' => 'hart',
    'Hartlepool' => 'hartlepool',

    // ... continue adding all councils in the same format
];

/**
 * STEP B: Add a multi-select dropdown to the PMPro checkout
 */
add_action('pmpro_checkout_after_level_cost', function() use ($councils) {
    if(pmpro_getLevel()->name !== 'Single Council Access') return;

    echo '<div class="pmpro_checkout-field pmpro_checkout-field-councils">';
    echo '<label for="council_selection">Select Councils (£5 each):</label>';
    echo '<select id="council_selection" name="council_selection[]" multiple size="10" style="width:100%;">';

    foreach($councils as $name => $slug) {
        echo '<option value="'.esc_attr($slug).'">'.esc_html($name).'</option>';
    }

    echo '</select>';
    echo '<p style="font-size:0.9em;color:#666;">Hold Ctrl (Windows) or Cmd (Mac) to select multiple.</p>';
    echo '</div>';
});

/**
 * STEP C: Validate at checkout (must select at least one)
 */
add_filter('pmpro_registration_checks', function($okay) {
    if(pmpro_getLevel()->name === 'Single Council Access' && empty($_REQUEST['council_selection'])) {
        pmpro_setMessage("Please select at least one council.", "pmpro_error");
        return false;
    }
    return $okay;
});

/**
 * STEP D: Save selected councils to user meta
 */
add_action('pmpro_after_checkout', function($user_id) {
    if(!empty($_REQUEST['council_selection'])) {
        update_user_meta($user_id, 'selected_councils', array_map('sanitize_text_field', $_REQUEST['council_selection']));
    }
});

/**
 * STEP E: Calculate price dynamically (£5 per council)
 */
add_filter('pmpro_level_cost_text', function($cost, $level) {
    if($level->name === 'Single Council Access' && !empty($_REQUEST['council_selection'])) {
        $count = count($_REQUEST['council_selection']);
        $total = $count * 5;
        return "£{$total} total (£5 per council)";
    }
    return $cost;
}, 10, 2);

/**
 * STEP F: Restrict access based on selected councils
 */
function user_has_council_access($slug) {
    $user_id = get_current_user_id();
    $councils = get_user_meta($user_id, 'selected_councils', true);
    return is_array($councils) && in_array($slug, $councils, true);
}
