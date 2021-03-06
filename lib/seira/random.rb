require 'csv'

# For random names for building Jobs, pods, and other resources
module Seira
  class Random
    MAX_UNIQUE_NAME_ATTEMPTS = 10

    def self.unique_name(existing = [])
      attempts = 0
      loop do
        name = "#{adjective}-#{animal}"
        attempts += 1
        return name unless existing.include? name
        return name unless unallowed_name?(name)
        fail "Too many failed unique name attempts" if attempts > MAX_UNIQUE_NAME_ATTEMPTS
      end
    end

    def self.unallowed_name?(name)
      # Robin always keeps his cool
      return true if name == "exasperated-robin"

      false
    end

    # List sourced from https://www.mobap.edu/wp-content/uploads/2013/01/list_of_adjectives.pdf
    def self.adjective
      adjectives_lis_file = File.join(File.expand_path('../..', File.dirname(__FILE__)), 'resources', 'adjectives.txt')
      CSV.open(adjectives_lis_file, "r").map(&:first).map(&:chomp).map(&:strip).sample
    end

    def self.animal
      %w[
        aardvark
        abyssinian
        affenpinscher
        akbash
        akita
        albatross
        alligator
        alpaca
        angelfish
        ant
        anteater
        antelope
        ape
        armadillo
        avocet
        axolotl
        baboon
        badger
        balinese
        bandicoot
        barb
        barnacle
        barracuda
        bat
        beagle
        bear
        beaver
        bee
        beetle
        binturong
        bird
        birman
        bison
        bloodhound
        boar
        bobcat
        bombay
        bongo
        bonobo
        booby
        budgerigar
        buffalo
        bulldog
        bullfrog
        burmese
        butterfly
        caiman
        camel
        capybara
        caracal
        caribou
        cassowary
        cat
        caterpillar
        catfish
        cattle
        centipede
        chameleon
        chamois
        cheetah
        chicken
        chihuahua
        chimpanzee
        chinchilla
        chinook
        chipmunk
        chough
        cichlid
        clam
        coati
        cobra
        cockroach
        cod
        collie
        coral
        cormorant
        cougar
        cow
        coyote
        crab
        crane
        crocodile
        crow
        curlew
        cuscus
        cuttlefish
        dachshund
        dalmatian
        deer
        dhole
        dingo
        dinosaur
        discus
        dodo
        dog
        dogfish
        dolphin
        donkey
        dormouse
        dotterel
        dove
        dragonfly
        drever
        duck
        dugong
        dunker
        dunlin
        eagle
        earwig
        echidna
        eel
        eland
        elephant
        elk
        emu
        falcon
        ferret
        finch
        fish
        flamingo
        flounder
        fly
        fossa
        fox
        frigatebird
        frog
        galago
        gar
        gaur
        gazelle
        gecko
        gerbil
        gharial
        gibbon
        giraffe
        gnat
        gnu
        goat
        goldfinch
        goldfish
        goose
        gopher
        gorilla
        goshawk
        grasshopper
        greyhound
        grouse
        guanaco
        gull
        guppy
        hamster
        hare
        harrier
        havanese
        hawk
        hedgehog
        heron
        herring
        himalayan
        hippopotamus
        hornet
        horse
        human
        hummingbird
        hyena
        ibis
        iguana
        impala
        indri
        insect
        jackal
        jaguar
        javanese
        jay
        jellyfish
        kakapo
        kangaroo
        kingfisher
        kiwi
        koala
        kouprey
        kudu
        labradoodle
        ladybird
        lapwing
        lark
        lemming
        lemur
        leopard
        liger
        lion
        lionfish
        lizard
        llama
        lobster
        locust
        loris
        louse
        lynx
        lyrebird
        macaw
        magpie
        mallard
        maltese
        manatee
        mandrill
        markhor
        marten
        mastiff
        mayfly
        meerkat
        millipede
        mink
        mole
        molly
        mongoose
        mongrel
        monkey
        moorhen
        moose
        mosquito
        moth
        mouse
        mule
        narwhal
        newt
        nightingale
        numbat
        ocelot
        octopus
        okapi
        olm
        opossum
        orang-utan
        oryx
        ostrich
        otter
        owl
        ox
        oyster
        pademelon
        panther
        parrot
        partridge
        peacock
        peafowl
        pekingese
        pelican
        penguin
        persian
        pheasant
        pig
        pigeon
        pika
        pike
        piranha
        platypus
        pointer
        pony
        poodle
        porcupine
        porpoise
        possum
        prawn
        puffin
        pug
        puma
        quail
        quelea
        quetzal
        quokka
        quoll
        rabbit
        raccoon
        ragdoll
        rail
        ram
        rat
        rattlesnake
        raven
        reindeer
        rhinoceros
        robin
        rook
        rottweiler
        ruff
        salamander
        salmon
        sandpiper
        saola
        sardine
        scorpion
        seahorse
        seal
        serval
        shark
        sheep
        shrew
        shrimp
        siamese
        siberian
        skunk
        sloth
        snail
        snake
        snowshoe
        somali
        sparrow
        spider
        sponge
        squid
        squirrel
        starfish
        starling
        stingray
        stinkbug
        stoat
        stork
        swallow
        swan
        tang
        tapir
        tarsier
        termite
        tetra
        tiffany
        tiger
        toad
        tortoise
        toucan
        tropicbird
        trout
        tuatara
        turkey
        turtle
        uakari
        uguisu
        umbrellabird
        unicorn
        viper
        vulture
        wallaby
        walrus
        warthog
        wasp
        weasel
        whale
        whippet
        wildebeest
        wolf
        wolverine
        wombat
        woodcock
        woodlouse
        woodpecker
        worm
        wrasse
        wren
        yak
        zebra
        zebu
        zonkey
        zorse
      ].sample
    end
  end
end
