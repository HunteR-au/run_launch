import time
import random

# List of random words
words = ["apple", "banana", "cherry", "date", "elderberry"]

# Initialize counter
counter = 1

#print(f"test\nnoun\nrabbit\nhenry\n")

while True:
    # Choose a random word from the list
    word = random.choice(words)
    
    # Print the counter and the random word
    print(f"{counter}: {word}")
    
    # Increment the counter
    counter += 1
    
    #if (counter == 5):
    #    while True:
    #        pass

    # Wait for 10 seconds
    time.sleep(1)
